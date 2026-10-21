#!/bin/bash
# Real, non-interactive keychain E2E using synthetic items and two changed binaries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT="${KEYCHAIN_CONTINUITY_REPORT_DIR:-$ROOT/TestResults/release-signing-reuse/keychain-continuity}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bigbang-keychain-continuity.XXXXXX")"
DEV_UUID="$(uuidgen)"
ADHOC_UUID="$(uuidgen)"
DEV_SERVICE="app.mayfiles.BigBang.signing-fixture.$DEV_UUID"
ADHOC_SERVICE="app.mayfiles.BigBang.signing-fixture.$ADHOC_UUID"
DEV_BUNDLE="app.mayfiles.BigBang.signing-fixture.developer.$DEV_UUID"
ADHOC_BUNDLE="app.mayfiles.BigBang.signing-fixture.adhoc.$ADHOC_UUID"
mkdir -p "$REPORT"
: > "$REPORT/cleanup.log"
printf 'RUNNING: synthetic non-interactive keychain continuity check.\n' > "$REPORT/result.log"

cleanup() {
    local result=0
    if [ -x "$WORK/developer-v1.app/Contents/MacOS/KeychainIdentityFixture" ]; then
        "$WORK/developer-v1.app/Contents/MacOS/KeychainIdentityFixture" delete "$DEV_SERVICE" "$DEV_UUID" >> "$REPORT/cleanup.log" 2>&1 || result=1
    fi
    if [ -x "$WORK/adhoc-v1.app/Contents/MacOS/KeychainIdentityFixture" ]; then
        "$WORK/adhoc-v1.app/Contents/MacOS/KeychainIdentityFixture" delete "$ADHOC_SERVICE" "$ADHOC_UUID" >> "$REPORT/cleanup.log" 2>&1 || result=1
    fi
    rm -rf "$WORK"
    if [ "$result" != 0 ]; then
        printf 'Synthetic keychain cleanup failed; inspect %s\n' "$REPORT/cleanup.log" >&2
    fi
    return "$result"
}
finish() {
    local status="$?"
    trap - EXIT
    if ! cleanup; then status=1; fi
    if [ "$status" != 0 ]; then
        printf 'FAIL: check or cleanup did not complete (exit %s); inspect the operation logs.\n' "$status" > "$REPORT/result.log"
    fi
    exit "$status"
}
trap finish EXIT

source "$ROOT/scripts/lib/signing.sh"
macos_signing_resolve "${MACOS_SIGNING_IDENTITY:-}" "${CODE_SIGN_KEYCHAIN:-}" 1 > "$REPORT/resolve.log" 2>&1
case "$MACOS_SIGN_NAME" in
    'Developer ID Application: '*) ;;
    *) printf 'This E2E requires a real Developer ID Application certificate.\n' >&2; exit 1 ;;
esac

export CLANG_MODULE_CACHE_PATH="$WORK/module-cache"
# Match Package.swift's macOS 14 deployment target in both compiler drivers.
FIXTURE_TARGET="$(uname -m)-apple-macosx14.0"
printf 'target=%s\nC flags=-Wall -Wextra -Werror\nSwift flags=-warnings-as-errors -Xcc -Werror\n' "$FIXTURE_TARGET" > "$REPORT/compile-settings.log"
xcrun clang -target "$FIXTURE_TARGET" -Wall -Wextra -Werror -c "$ROOT/Tests/Fixtures/KeychainInteractionCompatibility.c" -o "$WORK/keychain-interaction.o" > "$REPORT/compile.log" 2>&1
SWIFT_ARGS=(-target "$FIXTURE_TARGET" -O -warnings-as-errors -Xcc -Werror -import-objc-header "$ROOT/Tests/Fixtures/KeychainInteractionCompatibility.h")
xcrun swiftc "${SWIFT_ARGS[@]}" "$ROOT/Tests/Fixtures/KeychainIdentityFixture.swift" "$WORK/keychain-interaction.o" -o "$WORK/fixture-v1" >> "$REPORT/compile.log" 2>&1
xcrun swiftc "${SWIFT_ARGS[@]}" -D FIXTURE_V2 "$ROOT/Tests/Fixtures/KeychainIdentityFixture.swift" "$WORK/keychain-interaction.o" -o "$WORK/fixture-v2" >> "$REPORT/compile.log" 2>&1

make_app() {
    local kind="$1" version="$2" bundle="$3" app="$WORK/$1-v$2.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$WORK/fixture-v$version" "$app/Contents/MacOS/KeychainIdentityFixture"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleExecutable</key><string>KeychainIdentityFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
}

metadata() {
    local kind="$1" version="$2" app="$WORK/$1-v$2.app"
    codesign --display --verbose=4 "$app" 2>&1 | awk '/^Identifier=|^CDHash=|^TeamIdentifier=|^Authority=|^CodeDirectory |^Timestamp=|^Signature=/' > "$REPORT/$kind-v$version.metadata.log"
    codesign --display -r- "$app" 2>&1 | sed -n -E '/^(# )?designated => /p' > "$REPORT/$kind-v$version.requirement.log"
    test -s "$REPORT/$kind-v$version.requirement.log"
}

run_fixture() {
    local kind="$1" version="$2" action="$3" service="$4" account="$5"
    "$WORK/$kind-v$version.app/Contents/MacOS/KeychainIdentityFixture" "$action" "$service" "$account" > "$REPORT/$kind-v$version-$action.json"
}

make_app developer 1 "$DEV_BUNDLE"
make_app developer 2 "$DEV_BUNDLE"
macos_signing_sign_app "$WORK/developer-v1.app" "$DEV_BUNDLE" "" "" > "$REPORT/developer-v1.sign.log" 2>&1
macos_signing_sign_app "$WORK/developer-v2.app" "$DEV_BUNDLE" "$WORK/developer-v1.app" "" > "$REPORT/developer-v2.sign.log" 2>&1
metadata developer 1
metadata developer 2
cmp "$REPORT/developer-v1.requirement.log" "$REPORT/developer-v2.requirement.log"
DEV_HASH_1="$(sed -n 's/^CDHash=//p' "$REPORT/developer-v1.metadata.log")"
DEV_HASH_2="$(sed -n 's/^CDHash=//p' "$REPORT/developer-v2.metadata.log")"
test -n "$DEV_HASH_1" && test -n "$DEV_HASH_2" && test "$DEV_HASH_1" != "$DEV_HASH_2"
run_fixture developer 1 create "$DEV_SERVICE" "$DEV_UUID"
run_fixture developer 1 read "$DEV_SERVICE" "$DEV_UUID"
run_fixture developer 2 read "$DEV_SERVICE" "$DEV_UUID"

make_app adhoc 1 "$ADHOC_BUNDLE"
make_app adhoc 2 "$ADHOC_BUNDLE"
macos_signing_resolve - "" 0 > "$REPORT/adhoc.resolve.log" 2>&1
macos_signing_sign_app "$WORK/adhoc-v1.app" "$ADHOC_BUNDLE" "" "" > "$REPORT/adhoc-v1.sign.log" 2>&1
# No continuity enforcement here: a changed ad hoc identity is the negative control.
macos_signing_sign_app "$WORK/adhoc-v2.app" "$ADHOC_BUNDLE" "" "" > "$REPORT/adhoc-v2.sign.log" 2>&1
metadata adhoc 1
metadata adhoc 2
if cmp -s "$REPORT/adhoc-v1.requirement.log" "$REPORT/adhoc-v2.requirement.log"; then
    printf 'Ad hoc negative control unexpectedly retained its designated requirement.\n' >&2
    exit 1
fi
ADHOC_HASH_1="$(sed -n 's/^CDHash=//p' "$REPORT/adhoc-v1.metadata.log")"
ADHOC_HASH_2="$(sed -n 's/^CDHash=//p' "$REPORT/adhoc-v2.metadata.log")"
test -n "$ADHOC_HASH_1" && test -n "$ADHOC_HASH_2" && test "$ADHOC_HASH_1" != "$ADHOC_HASH_2"
run_fixture adhoc 1 create "$ADHOC_SERVICE" "$ADHOC_UUID"
run_fixture adhoc 1 read "$ADHOC_SERVICE" "$ADHOC_UUID"
if run_fixture adhoc 2 read "$ADHOC_SERVICE" "$ADHOC_UUID"; then
    printf 'Ad hoc negative control unexpectedly read the item without interaction.\n' >&2
    exit 1
fi
# Require an authorization/interaction failure, not item absence or an unrelated error.
if ! grep -Eq '"status":(-25308|-25293)[,}]' "$REPORT/adhoc-v2-read.json"; then
    printf 'Ad hoc negative control failed with an unexpected OSStatus; inspect %s\n' "$REPORT/adhoc-v2-read.json" >&2
    exit 1
fi
printf 'PASS: changed Developer ID binaries retain DR and read the synthetic item without interaction; changed ad hoc binaries fail authorization.\n' > "$REPORT/result.log"
cat "$REPORT/result.log"
printf 'Evidence: %s\n' "$REPORT"
