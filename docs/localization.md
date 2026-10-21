# Localization

## Supported Languages

The app supports Simplified Chinese (`zh-Hans`) and English (`en`). On first launch, it chooses the first supported language in macOS preference order, falling back to English. Language choices always use their own names: **简体中文** and **English**.

## Runtime Behavior

An explicit selection is saved immediately. Existing windows, menus, app-generated notices, errors and accessibility labels update without restarting. macOS-owned permission dialogs use the system language.

Language changes update untouched built-in preset names and prompts. Customized names, prompts, presets, UUIDs, order and shortcuts are preserved. Generated note text remains unchanged.

## Adding UI Copy

Store app-owned translations in `Sources/BigBangCore/Resources/en.lproj/Localizable.strings` and `Sources/BigBangCore/Resources/zh-Hans.lproj/Localizable.strings`. Both tables must contain the same keys and compatible format arguments. Existing Chinese source phrases are valid resource keys; built-in preset names and instructions use stable `preset.*` keys. Keep translated values out of Swift code.

Use `L10n` with the explicit application language. `LocalizationResources.swift` is shared with the other apps and resolves the requested language, then English, then the key. The packaged app loads `BigBang_BigBangCore.bundle` from its own resources; SwiftPM tests use `Bundle.module`. Xcode builds obtain the same resource bundle through the local `BigBangCore` package product.

`RuntimeTranslations` recognizes only known app-owned status and failure messages. Preserve user content and unknown errors when switching languages. Keep format arguments and accessibility labels aligned in both languages.

`Resources/en.lproj/InfoPlist.strings` and `Resources/zh-Hans.lproj/InfoPlist.strings` contain localized bundle display and permission strings. Use `BigBang` for code and bundle identity, **Big Bang** for the English display name and **大爆炸** for Simplified Chinese.

## Validation

Run resource and localization unit tests with `./scripts/app.py test`. For a prebuilt bundle, use the common native localization entrypoint:

```sh
./scripts/app.py test --native --case localization \
  --app /Applications/BigBang.app \
  --output /private/tmp/big-bang-localization --timeout-seconds 90
```

Use a visible macOS desktop and a fresh output directory. The existing product runner writes `manifest.json`, `localization-flow.json`, logs, and bilingual window previews. A native failure, incomplete check, timeout, or failed cleanup makes the run fail; inspect its artifacts before retrying.

The fixture uses isolated preferences and native Settings controls to switch both ways without restarting. It checks existing notes, menus, errors, accessibility labels, formatted text, preset preservation, and saved language selection. It does not read Keychain, contact a model, or change real login items. macOS-owned permission dialogs follow the system language.

The shared recorder owns a fresh preference suite and `fixture-data` directory for each localization run. It removes both after the owned fixture process ends, including failure, timeout, and interruption, and records cleanup independently in the manifest. The production BigBang process and its settings remain untouched. Progress, reports, logs, and screenshots are retained as evidence.

For real cleanup checks, set `MACOS_LOCALIZATION_TEST_MODE=fail` to fail after native English controls, menus, and an existing note are verified. Set it to `hold` to pause at the same point for a deadline or Ctrl-C check. Wait for `localization-progress.json` with `stage: english-visible` before interrupting. These scenarios must return a failure even when cleanup succeeds; use a fresh output directory for each run.
