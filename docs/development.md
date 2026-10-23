# Development

## Requirements

Use Xcode 27 or later, macOS SDK 27 or later, Swift 6.4 or later and Python 3. The deployment minimum is macOS 14.0. Run commands from the repository root.

## Command-Line Workflow

```sh
./scripts/app.py build
./scripts/app.py run
./scripts/app.py test
./scripts/app.py package
./scripts/app.py release --dry-run
```

Build and Run default to Debug, the native architecture and automatic signing. The bundle is `dist/dev/BigBang.app`. Codex Run uses `./scripts/app.py run`; it builds, normally stops the same development app and launches its replacement. Another running path with the same identity blocks Run. A build failure leaves the running app intact.

Pass app arguments after `--`. `macos-app.json` declares identity, resources and build settings; `VERSION` supplies the marketing version. The shared CLI uses SwiftPM for builds and tests. Package defaults to Release, Universal and ad-hoc signing under `dist/release/universal/`; see [Releasing](releasing.md) for Developer ID options. `release --dry-run` displays the release plan without building or contacting Apple or GitHub.

Shared scripts, workflows, and declared design and localization helpers are maintained in `macos-app-tooling/templates/macos-app`. The `shared` object in this repository's `macos-app.json` declares helper destinations relative to this repository. Update shared implementation in macos-app-tooling, then run from its checkout root:

```sh
python3 -B scripts/sync_apps.py --check APP_CHECKOUT
python3 -B scripts/sync_apps.py --apply APP_CHECKOUT
```

Replace `APP_CHECKOUT` with this app's checkout directory; multiple explicit checkout arguments are accepted. The check is read-only; apply copies shared files. Review local and staged changes before applying and inspect the resulting diff. Checkouts can live in any directory: do not commit host-specific paths or a workspace layout. App configuration, translations, product behavior and targeted checks stay in this repository. Follow [Shared Maintenance](https://github.com/mayflies-app/macos-app-tooling/tree/main/templates/macos-app#shared-maintenance) for validation scope.

## Xcode Workflow

Open `BigBang.xcodeproj` and select the `BigBang` scheme for Build, Run, Debug or Archive. The native app target consumes the local Swift package libraries. Xcode and the CLI use the same product identity and bundled resources.

Debug and Release use ad-hoc signing by default and do not require an Apple Developer team. Hardened Runtime remains enabled. For Developer ID distribution, explicitly select your signing identity and team in Xcode, or use the command-line and CI workflow in [Releasing](releasing.md).

## Product Checks

`./scripts/app.py test` runs Swift tests for configuration, presets, streaming, selection and clipboard behavior, followed by the offline native-wrapper contract checks in `Tests/Tools/test-verify-native.sh`. These checks use an isolated fake app and helper without opening the GUI. `macos-app.json` lists the additional checks in `testScripts`.

Native checks cover settings input, note layout and preset switching. For a prebuilt bundle:

```sh
bash Tests/Tools/verify_native.sh --app "$PWD/dist/dev/BigBang.app" \
  --output /private/tmp/bigbang-settings --appearance standard
```

The targeted runner writes fresh reports and logs without changing user settings, reading Keychain, calling a model or registering login items. The settings-input case also checks window close, recorder cancellation, undo/redo, select-all and copy/cut/paste through native key events. Clipboard editing preserves and restores every available clipboard format; if another application writes meanwhile, its new clipboard is retained and the restoration check fails. It temporarily registers Control-Option-Shift-Command digit shortcuts to verify preset dispatch and reordered mappings; physical event injection runs only when event-posting access is already available, as recorded in the report. Use the common `test` command for offline coverage and select only the native cases needed for the change. Selection, native input methods and real clipboard behavior require a visible desktop and coordinated focus.

For the shared bilingual UI check, run `./scripts/app.py test --native --case localization --app /Applications/BigBang.app --output /private/tmp/big-bang-localization --timeout-seconds 90`. This invokes the existing product runner with a prebuilt bundle; it does not build or sign. See [Localization](localization.md) for coverage and restoration behavior.

### Explicit Live API Diagnosis

Only run this diagnostic with the user's authorization to read the saved Keychain credential and contact their configured service:

```sh
./scripts/app.py build --configuration release --sign developer-id
mkdir -p TestResults/live-api
open -n -W "$PWD/dist/dev/BigBang.app" --args --diagnose-live-api \
  --report "$PWD/TestResults/live-api/report.json"
```

The diagnostic requires a Developer ID Release app with the existing app identity. It reads the current configuration and Keychain without changing them, sends three fixed, non-sensitive probes (Responses, Chat Completions, and a Responses wire-structure check), and exits. It bypasses normal UI and shortcut registration. The report contains completion state, text length, probe-match checks, HTTP status, event field names/types and SDK decoding paths; it omits credentials, headers, generated text and raw provider errors. Ordinary tests and native fixtures never invoke it.

Both API modes use the same per-request URLSession transport and bounded SSE decoder. Sessions are ephemeral, with cookies, URL caches and credential storage disabled. Cancellation targets an already-created URLSessionDataTask; the session is invalidated after the task finishes. The shared decoder accepts CR, LF and CRLF, fragmented UTF-8/BOM and multiline data, with 2 MB limits on lines and events and a 64 KiB HTTP error-body limit. The request inactivity timeout is 60 seconds.

Protocol adapters interpret only displayed text, refusals and terminal events. Responses does not require optional usage metadata or decode reasoning items. Chat Completions consumes choice zero and requires a normal stop reason. Both retain ordered events, safe errors and explicit successful completion; EOF or a standalone `[DONE]` cannot turn a truncated result into success. Existing protocol-specific output-token budgets are unchanged.

### Resource Tools

- `tools/markdown/`: `npm ci`, `npm test`, `npm run build`; see its [README](../tools/markdown/README.md). Ordinary app builds use committed resources and do not need Node.js.
- `tools/make-icon.swift`: icon generation, followed by `iconutil` to update the ICNS resource.
- `Tests/Tools/build-external-selection-fixture.sh`: isolated selection fixture.
- `Tests/Tools/verify-keychain-continuity.sh`: explicit Developer ID check using synthetic Keychain items; ordinary builds and tests do not invoke it.

Prebuilt native runners require an absolute app path and a new or empty output directory. Keep local output in `TestResults/` or a temporary directory. A fixture result covers its scenario; separately check real permissions, login registration, input methods, hardware or live services when those behaviors are affected.
