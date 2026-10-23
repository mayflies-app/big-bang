# Contributing

Focused fixes, documentation improvements and reproducible bug reports are welcome. Discuss substantial product changes before implementation.

## Setup

Follow [Development](docs/development.md) to build and run the app. Read [Localization](docs/localization.md) before changing UI copy and [Releasing](docs/releasing.md) for packaging.

## Changes

Preserve accessory-app focus, nonactivating notes, preset UUIDs, original-input retry and cancellation, native input methods, global shortcuts, selection fallback and restoration of every clipboard format. Changing the interface language must preserve customized presets and generated note content. Keep API keys out of settings and logs.

Shared scripts, workflows, and declared design and localization helpers are maintained in `macos-app-tooling/templates/macos-app`. This repository declares its repository-relative helper destinations in the `shared` object of `macos-app.json`; app configuration, translations, product behavior and targeted checks belong here. Update shared implementation in macos-app-tooling and synchronize from its root with explicit app checkout arguments after reviewing local and staged changes. Do not commit host-specific paths or assume a workspace layout. See [Shared Maintenance](https://github.com/mayflies-app/macos-app-tooling/tree/main/templates/macos-app#shared-maintenance).

## Validation

Match validation to the change. For documentation only, check links, referenced paths and `git diff --check`; no app build or product test is needed. For executable changes, run `./scripts/app.py test` and the affected checks in [Development](docs/development.md). Build, package or inspect native UI only when the change affects those behaviors.

Reproduce bugs before fixing them and add regression coverage where existing tests leave a meaningful gap. Use isolated data for native checks and retain fresh logs or screenshots for interaction changes. Fixtures must not call a live model or change login items. Keep generated output, credentials and signing files out of commits.

## Submission

Describe the user-visible problem, resulting behavior and checks performed. Bug reports should include the app version, macOS version, Mac architecture and reproduction steps. Redact personal content and credentials. Report sensitive security issues to [nshcr](https://github.com/nshcr) without posting secrets publicly.

Contributions use the [MIT license](LICENSE). Preserve copyright attribution.
