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

With `dry_run=false`, the common `./scripts/app.py release` entrypoint builds one Universal package containing arm64 and x86_64, signs it with Developer ID, submits its DMG for Apple notarization and staples the accepted result. With `publish=true`, it also publishes verified release assets and updates the Homebrew cask from the Universal DMG. Execute these modes only for an explicitly authorized release.

Verify the release source commit, signature, Hardened Runtime, notarization acceptance, stapling and asset checksums before distributing the app. A local signed package demonstrates local signing; public distribution requires the notarized assets produced by the release workflow.

### Cache and Execution

Dry-run uses the `preview` job on `ubuntu-latest`, without credentials or build-cache access. Execution follows `preflight → package → notarize → publish → cask`, using the common `./scripts/app.py release --execute --stage <job>` entrypoint. `package` and `notarize` use GitHub-hosted `xcode-27` with Xcode 27; the other jobs use `ubuntu-latest`. Signing secrets are scoped to `package`, notarization secrets and Team ID to `notarize`, Contents write to `publish`, and `HOMEBREW_TAP_TOKEN` to `cask`. `publish=false` stops after notarization. A matching public version reuses verified public assets and skips rebuilding and notarization. Release runs are serialized and never cancel an in-progress execution.

Use **Re-run failed jobs** or re-run a failed job itself to reuse successful upstream work. Jobs download immutable inputs by the producer's artifact ID; the signed app travels in a tar archive preserving executable modes and symlinks. Notarization resumes a retained submission ID after checking the original DMG checksum. Draft publication verifies existing bytes and uploads only missing assets. Empty `starter` placeholders from failed uploads are removed only after all completed assets pass byte verification; an already published release is verified without further writes. Missing artifact IDs stop before download, without falling back to all artifacts. A cask retry only verifies public assets and updates the tap. Build cache saving completes in `package` even if a later job fails.

Keep workflow artifacts until completion. Expired inputs require a new run. If a prior notary execution has no retained submission ID, inspect Apple submission history before starting a new workflow run. Re-running all jobs can produce different signed bytes that cannot reuse the previous checkpoint. See [shared release retries](https://github.com/mayflies-app/macos-app-tooling/blob/main/docs/releasing.md#retry-a-failed-job) for recovery boundaries. Ordinary CI retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Changed inputs still rebuild. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

The distribution tap is [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap). The release workflow prepares `bigbang` from the verified Universal DMG and updates the tap through the shared release entrypoint. Its URL, version, SHA-256 checksum, bundle name and minimum macOS version must match the published asset.

## Release Diagnostics

Release logs identify stages, failure kinds and external exit codes, with credential-safe
GitHub error annotations. See [shared release diagnostics](https://github.com/mayflies-app/macos-app-tooling/blob/main/docs/releasing.md#release-diagnostics)
for authentication, authorization, repository access, network, concurrency and validation errors.
Tap updates use `HOMEBREW_TAP_TOKEN`, separately from the app workflow token.

A tap failure after successful publication leaves the release assets published. Repair
the cask from those verified public assets; do not rebuild or replace the same version.
Only confirmed concurrent push rejection is rebased and retried.
