# Releasing

## Configuration

`VERSION` supplies the marketing version. `macos-app.json` defines the `BigBang` product, `BigBang.app` bundle, `app.mayfiles.BigBang` identifier, release repository and `bigbang` cask token. A command-line `--version` override affects only that build.

Before running a release, confirm that `macos-app.json` points to the GitHub repository hosting the workflow. The configured release destination is `mayflies-app/big-bang`. Repository identity must match before running the release workflow.

Configure these repository secrets for release execution:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID certificate and private key export |
| `MACOS_CERTIFICATE_PASSWORD` | Certificate export password |
| `MACOS_SIGNING_IDENTITY` | Developer ID Application signing identity |
| `MACOS_TEAM_ID` | Apple Developer team ID |
| `APPLE_NOTARIZATION_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARIZATION_ISSUER_ID` | App Store Connect issuer ID |
| `APPLE_NOTARIZATION_PRIVATE_KEY` | App Store Connect API private key |
| `HOMEBREW_TAP_TOKEN` | Token permitted to update the distribution tap |

The workflow uses its GitHub token for release assets. The notarization issuer ID is distinct from the signing team ID.

## Local Packaging

```sh
./scripts/app.py package
./scripts/app.py package --arch universal --sign developer-id
./scripts/app.py release --dry-run
```

Package defaults to Release, Universal and ad-hoc signing. Options include `--arch native|arm64|x86_64|universal`, `--configuration`, `--build`, `--output` and `--sign auto|ad-hoc|developer-id`. Output contains the app under `app/`, a DMG, JSON metadata and a SHA-256 checksum. Staged output is verified before replacing the destination.

Developer ID packaging requires an available signing identity and Hardened Runtime. Local signing uses `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID` and `CODE_SIGN_KEYCHAIN`. Packaging stays local. `release --dry-run` displays the release plan without building, contacting Apple or modifying GitHub.

## GitHub Actions Release

Manually dispatch **macOS release**. The version input defaults to `VERSION`. `dry_run` defaults to `true`; `publish` defaults to `false`.

With `dry_run=false`, the common `./scripts/app.py release` entrypoint builds one Universal package containing arm64 and x86_64, signs it with Developer ID, submits its DMG once for Apple notarization and staples the accepted result. With `publish=true`, it also publishes verified release assets and updates the Homebrew cask from the Universal DMG. Execute these modes only for an explicitly authorized release.

Verify the release source commit, signature, Hardened Runtime, notarization acceptance, stapling and asset checksums before distributing the app. A local signed package demonstrates local signing; public distribution requires the notarized assets produced by the release workflow.

### Cache and Execution

Dry-run uses a dedicated `ubuntu-latest` preview job without Xcode, signing credentials or build-cache access. Execution uses the GitHub-hosted `xcode-27` runner. Release jobs are serialized and never cancel an in-progress release. Ordinary CI cancels superseded runs and retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Changed inputs still rebuild. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

The distribution tap is [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap). The release workflow prepares `bigbang` from the verified Universal DMG and updates the tap through the shared release entrypoint. Its URL, version, SHA-256 checksum, bundle name and minimum macOS version must match the published asset.
