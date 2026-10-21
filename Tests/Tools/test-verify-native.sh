#!/bin/bash
# Consume the verification wrapper with an isolated prebuilt app and mock helper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
if (($#)) && [[ "$1" != --evidence-helper || $# != 2 || "$2" != /* || ! -x "$2" ]]; then
    printf 'Usage: %s [--evidence-helper /absolute/compiled/VerificationEvidence]\n' "$0" >&2
    exit 2
fi
exec python3 - "$ROOT/Tests/Tools/verify_native.sh" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

wrapper = Path(sys.argv[1])
if not wrapper.is_file():
    sys.exit(f"Wrapper is not available yet: {wrapper}")
python = sys.executable

def real_consumer_checks(evidence_helper):
    """Use the current Recorder with a CLI fake app through the relocated wrapper."""
    helper_path = Path(evidence_helper).resolve()
    source = wrapper.parents[2] / "scripts/lib/VerificationEvidence.swift"
    recorder_source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    artifact_parent = Path(os.environ.get("NATIVE_CONSUMER_EVIDENCE_DIR", str(Path(tempfile.gettempdir()) / "big-bang-native-consumer-evidence"))).resolve()
    artifact_parent.mkdir(parents=True, exist_ok=True)
    artifacts = Path(tempfile.mkdtemp(prefix="real-consumer-", dir=artifact_parent))
    fixture = f"#!{python}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
assert args[0] == "--settings-input-test", args
report = pathlib.Path(args[args.index("--report") + 1])
mode = os.environ["NATIVE_REAL_CASE"]
if mode == "malformed":
    report.write_text("{not json")
elif mode != "missing":
    payload = {"passed": mode not in ("false", "skip-false")}
    if mode == "ready":
        payload = {"ready": True}
    report.write_text(json.dumps(payload))
if mode == "source-mutation":
    with open("source.txt", "a") as stream:
        stream.write("mutation during fixture\\n")
if mode == "app-mutation":
    icon = pathlib.Path(__file__).parent.parent / "Resources/AppIcon.icns"
    with icon.open("ab") as stream:
        stream.write(b"mutation during fixture")
if mode == "skip-false":
    print("SKIP: deliberately omitted fake check")
sys.exit(17 if mode == "nonzero" else 0)
'''
    with tempfile.TemporaryDirectory(prefix="big bang real CLI consumer ") as temporary:
        base = Path(temporary).resolve()
        project = base / "repo with spaces"
        (project / "Tests/Tools").mkdir(parents=True)
        (project / "scripts/lib").mkdir(parents=True)
        shutil.copy2(wrapper, project / "Tests/Tools/verify_native.sh")
        shutil.copy2(source, project / "scripts/lib/VerificationEvidence.swift")
        (project / "source.txt").write_text("baseline source\n")
        (project / ".gitignore").write_text(".build/\n")
        app = base / "CLI fixture with spaces/BigBang.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        resources = app / "Contents/Resources"
        for directory in (resources / "Markdown", resources / "zh-Hans.lproj", resources / "en.lproj"):
            directory.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundlePackageType="APPL", CFBundleIdentifier="app.mayfiles.BigBang", CFBundleExecutable="BigBang")))
        executable = app / "Contents/MacOS/BigBang"
        executable.write_text(fixture)
        executable.chmod(0o755)
        icon_bytes = b"fixture-icon"
        (resources / "AppIcon.icns").write_bytes(icon_bytes)
        (resources / "Markdown/sticky.js").write_text("// fixture\n")
        (resources / "Markdown/index.html").write_text("<!doctype html><script src=\"sticky.js\"></script>\n")
        for language in ("zh-Hans", "en"):
            (resources / f"{language}.lproj/InfoPlist.strings").write_text('"CFBundleName" = "Fixture";\n')
        mock_bin = base / "mock commands"
        mock_bin.mkdir()
        compiler = mock_bin / "swiftc"
        compiler.write_text(f"#!{python}\n" + f'''import os, shutil, sys
output = sys.argv[sys.argv.index("-o") + 1]
shutil.copy2({str(helper_path)!r}, output)
os.chmod(output, 0o755)
''')
        compiler.chmod(0o755)
        for command in (["git", "init", "--quiet"], ["git", "add", "."],
                        ["git", "-c", "user.name=Native CLI Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Fixture source baseline"]):
            subprocess.run(command, cwd=project, check=True, capture_output=True)
        cwd = base / "foreign working directory"
        cwd.mkdir()
        cases = (("true", "passed"), ("false", "failed"), ("missing", "failed"),
                 ("ready", "failed"), ("malformed", "failed"), ("nonzero", "failed"),
                 ("source-mutation", "invalidated"), ("app-mutation", "invalidated"), ("skip-false", "failed"))
        results = []
        for mode, expected_status in cases:
            (project / "source.txt").write_text("baseline source\n")
            (resources / "AppIcon.icns").write_bytes(icon_bytes)
            output = artifacts / mode
            environment = dict(os.environ, PATH=str(mock_bin) + os.pathsep + os.environ["PATH"], NATIVE_REAL_CASE=mode)
            result = subprocess.run(["/bin/bash", str(project / "Tests/Tools/verify_native.sh"), "--app", str(app), "--output", str(output)],
                                    cwd=cwd, env=environment, text=True, capture_output=True)
            (artifacts / (mode + "-wrapper.log")).write_text(result.stdout + result.stderr)
            manifest_path = output / "manifest.json"
            assert manifest_path.is_file(), f"{mode}: no manifest; exit={result.returncode}: {result.stderr}"
            manifest = json.loads(manifest_path.read_text())
            assert manifest["status"] == expected_status, f"{mode}: {manifest}"
            assert (result.returncode == 0) == (expected_status == "passed"), f"{mode}: exit={result.returncode}"
            assert manifest["project"] == "big-bang", manifest
            assert manifest["command"]["started"] is True, manifest
            assert manifest["report"]["successField"] == "passed", manifest
            if mode in ("true", "nonzero", "source-mutation", "app-mutation"):
                assert manifest["report"]["status"] == "passed", manifest
            else:
                assert manifest["report"]["status"] == "failed", manifest
            if mode == "nonzero":
                assert any("Child command failed" in error for error in manifest["errors"]), manifest
            if mode == "source-mutation":
                assert manifest["sourceBefore"]["fingerprintSHA256"] != manifest["sourceAfter"]["fingerprintSHA256"]
            if mode == "app-mutation":
                assert manifest["artifactBefore"]["bundleFingerprintSHA256"] != manifest["artifactAfter"]["bundleFingerprintSHA256"]
            if mode == "skip-false":
                assert manifest["observedSkips"] and manifest["evidenceQualifications"], manifest
            results.append(dict(case=mode, exit=result.returncode, status=manifest["status"], manifest=str(manifest_path)))
            print(f"PASS real Recorder consumer {mode}: {manifest['status']}")
        summary = dict(recorderSourceSHA256=recorder_source_sha, helper=str(helper_path), cases=results,
                       scope="CLI fake app only; no GUI, build, account, settings or Keychain validation")
        (artifacts / "consumer-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"All {len(results)} real Recorder CLI-consumer checks passed. Evidence: {artifacts}")

if len(sys.argv) > 2:
    real_consumer_checks(sys.argv[3])
    sys.exit(0)

logger = '''
import json, os, sys
def record(event, **fields):
    with open(os.environ["NATIVE_TEST_LOG"], "a") as stream:
        stream.write(json.dumps(dict(event=event, **fields)) + "\\n")
'''
helper = f"#!{python}\n" + logger + '''
record("evidence", argv=sys.argv[1:])
sys.exit(int(os.environ.get("NATIVE_TEST_HELPER_EXIT", "0")))
'''
compiler = f"#!{python}\n" + logger + f'''
record("compile", argv=sys.argv[1:])
status = int(os.environ.get("NATIVE_TEST_COMPILE_EXIT", "0"))
if status:
    sys.exit(status)
output = sys.argv[sys.argv.index("-o") + 1]
with open(output, "w") as stream:
    stream.write({helper!r})
os.chmod(output, 0o755)
'''
forbidden = f"#!{python}\n" + logger + '''
record("forbidden", argv=sys.argv)
sys.exit(99)
'''

with tempfile.TemporaryDirectory(prefix="big bang native consumer ") as temporary:
    base = Path(temporary).resolve()
    project = base / "repo with spaces"
    (project / "Tests/Tools").mkdir(parents=True)
    (project / "scripts/lib").mkdir(parents=True)
    (project / ".git").mkdir()
    copied = project / "Tests/Tools/verify_native.sh"
    shutil.copy2(wrapper, copied)
    (project / "scripts/lib/VerificationEvidence.swift").write_text("// Mock only.\n")
    bin_directory = base / "mock commands"
    bin_directory.mkdir()
    for path, source in ((bin_directory / "swiftc", compiler), (bin_directory / "swift", forbidden),
                         (bin_directory / "open", forbidden), (project / "scripts/app.py", forbidden),
                         (project / "scripts/lib/RunApp", forbidden)):
        path.write_text(source)
        path.chmod(0o755)
    app = base / "prebuilt with spaces/BigBang.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    resources = app / "Contents/Resources"
    for directory in (resources / "Markdown", resources / "zh-Hans.lproj", resources / "en.lproj"):
        directory.mkdir(parents=True)
    info = app / "Contents/Info.plist"
    valid_info = dict(CFBundlePackageType="APPL", CFBundleIdentifier="app.mayfiles.BigBang", CFBundleExecutable="BigBang")
    info.write_bytes(plistlib.dumps(valid_info))
    executable = app / "Contents/MacOS/BigBang"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    (resources / "AppIcon.icns").write_bytes(b"fixture-icon")
    (resources / "Markdown/sticky.js").write_text("// fixture\n")
    (resources / "Markdown/index.html").write_text("<!doctype html><script src=\"sticky.js\"></script>\n")
    for language in ("zh-Hans", "en"):
        (resources / f"{language}.lproj/InfoPlist.strings").write_text('"CFBundleName" = "Fixture";\n')
    cwd = base / "other working directory"
    cwd.mkdir()
    outputs = base / "evidence with spaces"
    outputs.mkdir()
    log = base / "events.jsonl"
    environment = os.environ.copy()
    for key in list(environment):
        if key.startswith("NATIVE_TEST_"):
            environment.pop(key)
    environment["PATH"] = str(bin_directory) + os.pathsep + environment["PATH"]
    environment["NATIVE_TEST_LOG"] = str(log)
    passed = 0
    sequence = 0
    output = None
    selected_case = os.environ.get("NATIVE_TEST_ONLY")

    def invoke(arguments, overrides=None):
        log.write_text("")
        result = subprocess.run(["/bin/bash", str(copied), *arguments], cwd=cwd,
                                env=dict(environment, **(overrides or {})), text=True, capture_output=True)
        events = [json.loads(line) for line in log.read_text().splitlines()]
        return result, events

    def check(name, extra=None, assertion=None, success=False, overrides=None, args=None):
        global passed, sequence, output
        if selected_case and selected_case != name:
            return
        sequence += 1
        output = outputs / f"run {sequence}"
        arguments = args if args is not None else ["--app", str(app), "--output", str(output), *(extra or [])]
        if "--output" in arguments and arguments.index("--output") + 1 < len(arguments):
            output = Path(arguments[arguments.index("--output") + 1])
        result, events = invoke(arguments, overrides)
        try:
            assert (result.returncode == 0) == success, f"exit={result.returncode}"
            if assertion:
                assertion(result, events)
            else:
                assert not events, events
        except AssertionError as error:
            sys.exit(f"FAIL {name}: {error}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}\nevents: {json.dumps(events)}")
        passed += 1
        print(f"PASS {name}")

    for arguments in (["--unknown"], ["--app"], ["--output"], ["--case"], ["--appearance"],
                      ["--timeout-seconds"], ["--app", str(app)], ["--output", str(outputs / "missing app")],
                      ["--help", "--unknown"], ["--", "free app argument"]):
        check("reject incomplete or unknown " + repr(arguments), args=arguments)
    for extra in (["--unknown"], ["free argument"], ["--", "--settings-input-test"],
                  ["--case", "selection"], ["--appearance", "glass"],
                  ["--app", str(app)], ["--output", str(outputs / "duplicate")],
                  ["--case", "settings-input", "--case", "settings-input"],
                  ["--appearance", "native", "--appearance", "standard"],
                  ["--timeout-seconds", "1", "--timeout-seconds", "2"]):
        check("reject invalid or duplicate " + repr(extra), extra=extra)
    for timeout in ("0", "-1", "NaN", "inf", "86400.01", "text"):
        check("reject timeout " + timeout, extra=["--timeout-seconds", timeout])

    def help_check(result, events):
        assert not events, events
        assert "--app" in result.stdout and "--output" in result.stdout, result.stdout
    check("standalone help has no side effects", args=["--help"], assertion=help_check, success=True)
    check("relative app rejected", args=["--app", os.path.relpath(app, cwd), "--output", str(outputs / "relative app")])
    check("relative output rejected", args=["--app", str(app), "--output", "relative evidence"])
    check("missing app rejected", args=["--app", str(base / "missing.app"), "--output", str(outputs / "missing")])
    check("missing output parent rejected", args=["--app", str(app), "--output", str(base / "absent parent/out")])
    check("output inside app rejected", args=["--app", str(app), "--output", str(resources / "evidence")])
    check("output inside git rejected", args=["--app", str(app), "--output", str(project / ".git/evidence")])
    history = outputs / "historical output"
    history.mkdir()
    (history / "old.json").write_text('{"passed":true}\n')
    check("nonempty historical output rejected", args=["--app", str(app), "--output", str(history)])
    link_target = outputs / "empty target"
    link_target.mkdir()
    symlink = outputs / "linked output"
    symlink.symlink_to(link_target, target_is_directory=True)
    check("symlink output rejected", args=["--app", str(app), "--output", str(symlink)])
    check("symlink output with trailing slash rejected", args=["--app", str(app), "--output", str(symlink) + "/"])
    file_output = outputs / "file output"
    file_output.write_text("")
    check("output file rejected", args=["--app", str(app), "--output", str(file_output)])
    read_only = outputs / "read only parent"
    read_only.mkdir()
    read_only.chmod(0o555)
    try:
        check("unwritable output parent rejected", args=["--app", str(app), "--output", str(read_only / "out")])
    finally:
        read_only.chmod(0o755)

    build_cache = project / ".build"
    for name, relative in (("output equal evidence helper cache rejected", "verification-evidence"),
                           ("output equal module cache rejected", "module-cache"),
                           ("output ancestor of build caches rejected", "."),
                           ("output inside evidence helper cache rejected", "verification-evidence/nested output"),
                           ("output inside module cache rejected", "module-cache/nested output")):
        if build_cache.exists():
            shutil.rmtree(build_cache)
        build_cache.mkdir()
        cache_output = build_cache if relative == "." else build_cache / relative
        cache_output.parent.mkdir(parents=True, exist_ok=True)
        check(name, args=["--app", str(app), "--output", str(cache_output)])

    for name, linked_cache in (("build cache symlink alias rejected", None),
                               ("evidence helper cache symlink alias rejected", "verification-evidence"),
                               ("module cache symlink alias rejected", "module-cache")):
        if build_cache.is_symlink():
            build_cache.unlink()
        elif build_cache.exists():
            shutil.rmtree(build_cache)
        external_target = base / name
        external_target.mkdir()
        if linked_cache is None:
            build_cache.symlink_to(external_target, target_is_directory=True)
        else:
            build_cache.mkdir()
            (build_cache / linked_cache).symlink_to(external_target, target_is_directory=True)
        check(name, args=["--app", str(app), "--output", str(external_target)])
    if build_cache.is_symlink():
        build_cache.unlink()
    elif build_cache.exists():
        shutil.rmtree(build_cache)

    for key, wrong in (("CFBundleIdentifier", "app.other.mac"), ("CFBundlePackageType", "BNDL"),
                       ("CFBundleExecutable", "Other")):
        info.write_bytes(plistlib.dumps(dict(valid_info, **{key: wrong})))
        check("reject incorrect " + key)
        info.write_bytes(plistlib.dumps(valid_info))
    info.write_text("malformed plist")
    check("malformed plist rejected")
    info.write_bytes(plistlib.dumps(valid_info))
    executable.chmod(0o644)
    check("nonexecutable app rejected")
    executable.chmod(0o755)
    for path in (resources / "AppIcon.icns", resources / "Markdown/sticky.js", resources / "Markdown/index.html",
                 resources / "zh-Hans.lproj/InfoPlist.strings", resources / "en.lproj/InfoPlist.strings"):
        backup = path.with_name(path.name + ".backup")
        path.rename(backup)
        try:
            check("missing resource rejected " + path.name)
        finally:
            backup.rename(path)
        contents = path.read_bytes()
        path.write_bytes(b"")
        try:
            check("empty resource rejected " + str(path.relative_to(resources)))
        finally:
            path.write_bytes(contents)

    def consumed(result, events, standard=False, timeout="300", localization=False):
        assert [event["event"] for event in events] == ["compile", "evidence"], events
        compile_args = events[0]["argv"]
        assert str(project / "scripts/lib/VerificationEvidence.swift") in compile_args
        assert compile_args[compile_args.index("-module-cache-path") + 1] == str(project / ".build/module-cache")
        assert compile_args[compile_args.index("-o") + 1] == str(project / ".build/verification-evidence/VerificationEvidence")
        report = str(output / ("localization-flow.json" if localization else "native-input.json"))
        expected = ["--project", "big-bang", "--repo", str(project), "--app", str(app),
                    "--output", str(output), "--expected-bundle-id", "app.mayfiles.BigBang",
                    "--report", report, "--success-field", "passed", "--timeout-seconds", timeout]
        if localization:
            expected.extend(["--localization-cleanup", "true"])
        expected.extend(["--", str(executable), "--preferences-test" if localization else "--settings-input-test"])
        if standard:
            expected.append("--standard-appearance")
        expected.extend(["--report", report])
        assert events[1]["argv"] == expected, events[1]

    check("prebuilt default native fixture consumes fixed argv", assertion=consumed, success=True)
    check("localization uses isolated preferences fixture and passed JSON", extra=["--case", "localization"],
          assertion=lambda result, events: consumed(result, events, localization=True), success=True)
    check("localization helper failure propagates", extra=["--case", "localization"],
          assertion=lambda result, events: consumed(result, events, localization=True), overrides={"NATIVE_TEST_HELPER_EXIT": "23"})
    empty_output = outputs / "existing empty output"
    empty_output.mkdir()
    check("existing empty output is accepted", args=["--app", str(app), "--output", str(empty_output)],
          assertion=consumed, success=True)
    check("explicit native appearance and decimal timeout", extra=["--case", "settings-input", "--appearance", "native", "--timeout-seconds", "1.25"],
          assertion=lambda result, events: consumed(result, events, timeout="1.25"), success=True)
    check("standard appearance maps to native fixture flag", extra=["--appearance", "standard", "--timeout-seconds", "86400"],
          assertion=lambda result, events: consumed(result, events, standard=True, timeout="86400"), success=True)
    check("helper failure propagates nonzero", assertion=consumed, overrides={"NATIVE_TEST_HELPER_EXIT": "23"})

    def failed_compile(result, events):
        assert [event["event"] for event in events] == ["compile"], events
    check("compile failure prevents evidence consumption", assertion=failed_compile,
          overrides={"NATIVE_TEST_COMPILE_EXIT": "24"})
    assert passed, f"No test matched NATIVE_TEST_ONLY={selected_case!r}"
    print(f"All {passed} isolated native-consumer checks passed.")
PY
