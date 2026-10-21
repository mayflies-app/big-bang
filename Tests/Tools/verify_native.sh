#!/usr/bin/env bash
set -euo pipefail

BB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BB_APP=""
BB_OUTPUT=""
BB_CASE="settings-input"
BB_APPEARANCE="native"
BB_TIMEOUT="300"
BB_HELP=0
BB_SEEN_APP=0
BB_SEEN_OUTPUT=0
BB_SEEN_CASE=0
BB_SEEN_APPEARANCE=0
BB_SEEN_TIMEOUT=0

usage() {
    cat <<'USAGE'
Usage: ./Tests/Tools/verify_native.sh --app /absolute/Big\ Bang.app --output /absolute/new-or-empty-directory
       [--case settings-input|localization] [--appearance native|standard] [--timeout-seconds N]
       ./Tests/Tools/verify_native.sh --help

Run the prebuilt Big Bang native fixture and record a fresh manifest,
scenario report, stdout.log and stderr.log. Localization checks native bilingual
Settings, existing notes, menus and accessibility labels with isolated preferences. No build, app stop or normal user
mode is performed. Output must be a new leaf under an existing writable parent
or an empty writable directory; previous results are never overwritten.
Timeout defaults to 300 seconds and must be positive and at most 86400.
The fixture reads user configuration at startup; it does not write user
preferences, access Keychain, call models or change login items.
USAGE
}

fail() {
    printf 'verify_native: %s\n' "$*" >&2
    exit 2
}

while (($#)); do
    case "$1" in
        --help)
            ((BB_HELP == 0)) || fail "Duplicate --help."
            BB_HELP=1
            shift
            ;;
        --app|--output|--case|--appearance|--timeout-seconds)
            (($# >= 2)) || fail "Missing value for $1."
            [[ -n "$2" && "$2" != --* ]] || fail "Missing value for $1."
            case "$1" in
                --app)
                    ((BB_SEEN_APP == 0)) || fail "Duplicate --app."
                    BB_APP="$2"; BB_SEEN_APP=1 ;;
                --output)
                    ((BB_SEEN_OUTPUT == 0)) || fail "Duplicate --output."
                    BB_OUTPUT="$2"; BB_SEEN_OUTPUT=1 ;;
                --case)
                    ((BB_SEEN_CASE == 0)) || fail "Duplicate --case."
                    BB_CASE="$2"; BB_SEEN_CASE=1 ;;
                --appearance)
                    ((BB_SEEN_APPEARANCE == 0)) || fail "Duplicate --appearance."
                    BB_APPEARANCE="$2"; BB_SEEN_APPEARANCE=1 ;;
                --timeout-seconds)
                    ((BB_SEEN_TIMEOUT == 0)) || fail "Duplicate --timeout-seconds."
                    BB_TIMEOUT="$2"; BB_SEEN_TIMEOUT=1 ;;
            esac
            shift 2
            ;;
        *) fail "Unknown argument: $1. Native case arguments are fixed." ;;
    esac
done

[[ "$BB_CASE" == settings-input || "$BB_CASE" == localization ]] || fail "Unknown case: $BB_CASE."
[[ "$BB_APPEARANCE" == native || "$BB_APPEARANCE" == standard ]] || fail "Appearance must be native or standard."
[[ "$BB_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "Timeout must be a positive finite number."
awk -v seconds="$BB_TIMEOUT" 'BEGIN { exit !(seconds > 0 && seconds <= 86400) }' || fail "Timeout must be in (0, 86400]."
if ((BB_HELP)); then
    usage
    exit 0
fi

[[ "$BB_APP" == /* && "$BB_APP" == *.app && -d "$BB_APP" ]] || fail "--app requires an absolute existing .app directory."
BB_APP="$(cd "$BB_APP" && pwd -P)"
BB_INFO="$BB_APP/Contents/Info.plist"
[[ -f "$BB_INFO" ]] || fail "App Info.plist is missing."
BB_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BB_INFO" 2>/dev/null)" || fail "App bundle identifier is missing."
[[ "$BB_ID" == app.mayfiles.BigBang ]] || fail "Wrong project app: expected app.mayfiles.BigBang."
BB_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BB_INFO" 2>/dev/null)" || fail "App executable metadata is missing."
[[ "$BB_EXECUTABLE" == BigBang ]] || fail "App executable must be BigBang."
BB_PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$BB_INFO" 2>/dev/null)" || fail "App package metadata is missing."
[[ "$BB_PACKAGE_TYPE" == APPL ]] || fail "App package type must be APPL."
BB_BINARY="$BB_APP/Contents/MacOS/BigBang"
[[ -f "$BB_BINARY" && -x "$BB_BINARY" ]] || fail "BigBang executable is missing or not executable."
for BB_RESOURCE in AppIcon.icns Markdown/index.html Markdown/sticky.js zh-Hans.lproj/InfoPlist.strings en.lproj/InfoPlist.strings; do
    [[ -s "$BB_APP/Contents/Resources/$BB_RESOURCE" ]] || fail "App resource missing: $BB_RESOURCE."
done

while [[ "$BB_OUTPUT" == */ && "$BB_OUTPUT" != / ]]; do
    BB_OUTPUT="${BB_OUTPUT%/}"
done
[[ "$BB_OUTPUT" == /* && ! -L "$BB_OUTPUT" ]] || fail "--output requires an absolute directory path, not a symlink."
BB_PARENT="$(dirname "$BB_OUTPUT")"
BB_LEAF="$(basename "$BB_OUTPUT")"
[[ "$BB_LEAF" != . && "$BB_LEAF" != .. && -d "$BB_PARENT" && -w "$BB_PARENT" ]] || fail "Output requires an existing writable parent."
BB_PARENT="$(cd "$BB_PARENT" && pwd -P)"
BB_OUTPUT="$BB_PARENT/$BB_LEAF"
[[ ! -L "$BB_OUTPUT" ]] || fail "Output cannot be a symlink."
if [[ -e "$BB_OUTPUT" ]]; then
    [[ -d "$BB_OUTPUT" && -w "$BB_OUTPUT" ]] || fail "Output must be a writable directory."
    [[ -z "$(find "$BB_OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "Output is nonempty; use a fresh directory."
fi
[[ "$BB_OUTPUT" != "$BB_APP" && "$BB_OUTPUT" != "$BB_APP/"* ]] || fail "Output cannot be inside the app."
[[ "$BB_OUTPUT" != "$BB_ROOT/.git" && "$BB_OUTPUT" != "$BB_ROOT/.git/"* ]] || fail "Output cannot be inside Git metadata."

BB_RECORDER_DIR="$BB_ROOT/.build/verification-evidence"
BB_MODULE_CACHE="$BB_ROOT/.build/module-cache"
for BB_CACHE in "$BB_ROOT/.build" "$BB_RECORDER_DIR" "$BB_MODULE_CACHE"; do
    [[ ! -L "$BB_CACHE" ]] || fail "Recorder compilation cache directories cannot be symlinks."
done
for BB_CACHE in "$BB_RECORDER_DIR" "$BB_MODULE_CACHE"; do
    [[ "$BB_OUTPUT" != "$BB_CACHE" && "$BB_OUTPUT" != "$BB_CACHE/"* && "$BB_CACHE" != "$BB_OUTPUT/"* ]] || fail "Output cannot overlap recorder compilation caches."
done
mkdir -p "$BB_RECORDER_DIR" "$BB_MODULE_CACHE"
swiftc -module-cache-path "$BB_MODULE_CACHE" \
    "$BB_ROOT/scripts/lib/VerificationEvidence.swift" -o "$BB_RECORDER_DIR/VerificationEvidence"

if [[ "$BB_CASE" == localization ]]; then
    BB_REPORT="$BB_OUTPUT/localization-flow.json"
    BB_NATIVE_ARGUMENTS=(--preferences-test)
else
    BB_REPORT="$BB_OUTPUT/native-input.json"
    BB_NATIVE_ARGUMENTS=(--settings-input-test)
fi
if [[ "$BB_APPEARANCE" == standard ]]; then
    BB_NATIVE_ARGUMENTS+=(--standard-appearance)
fi
BB_NATIVE_ARGUMENTS+=(--report "$BB_REPORT")
BB_EVIDENCE_ARGUMENTS=(--project big-bang --repo "$BB_ROOT" --app "$BB_APP" --output "$BB_OUTPUT"
    --expected-bundle-id app.mayfiles.BigBang --report "$BB_REPORT" --success-field passed
    --timeout-seconds "$BB_TIMEOUT")
if [[ "$BB_CASE" == localization ]]; then
    BB_EVIDENCE_ARGUMENTS+=(--localization-cleanup true)
fi
exec "$BB_RECORDER_DIR/VerificationEvidence" "${BB_EVIDENCE_ARGUMENTS[@]}" -- "$BB_BINARY" "${BB_NATIVE_ARGUMENTS[@]}"
