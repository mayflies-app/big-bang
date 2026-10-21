#!/bin/zsh
set -eu
fixture_source_dir="${0:A:h}/../Fixtures"
fixture_output="$(mktemp -d "${TMPDIR:-/tmp}/bigbang-selection-fixture.XXXXXX")"
fixture_bundle="$fixture_output/External Selection Fixture.app"
fixture_module_cache="$fixture_output/module-cache"
fixture_finished=0
trap 'if [[ "$fixture_finished" == 1 ]]; then rm -rf -- "$fixture_module_cache"; else rm -rf -- "$fixture_output"; fi' EXIT
mkdir -p "$fixture_bundle/Contents/MacOS" "$fixture_module_cache"
cat > "$fixture_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bigbang.external-selection-fixture</string>
<key>CFBundleName</key><string>External Selection Fixture</string>
<key>CFBundleExecutable</key><string>ExternalSelectionFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><false/>
</dict></plist>
PLIST
/usr/bin/swiftc -parse-as-library -module-cache-path "$fixture_module_cache" "$fixture_source_dir/ExternalSelectionFixture.swift" -o "$fixture_bundle/Contents/MacOS/ExternalSelectionFixture"
/usr/bin/codesign --force --sign - "$fixture_bundle"
fixture_finished=1
print -r -- "$fixture_bundle"
