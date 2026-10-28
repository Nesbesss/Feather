#!/bin/zsh
set -euo pipefail
task_root=${0:A:h:h:h}
task_fixture=$(mktemp -d /tmp/feather-extension-host.XXXXXX)
task_app="$task_fixture/FeatherExtensionHostFixture.app"
task_report=${1:-"$task_root/Tools/ExtensionsLab/results-host-smoke.json"}
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.nesbes.Feather.ExtensionHostFixture</string><key>CFBundleName</key><string>Feather Extension Host Fixture</string><key>CFBundleExecutable</key><string>HostSmoke</string><key>CFBundlePackageType</key><string>APPL</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  "$task_root/Feather/Engine/BrowserExtensions.swift" \
  "$task_root/Feather/Engine/WebExtensionAdapters.swift" \
  "$task_root/Feather/Engine/WebExtensionStore.swift" \
  "$task_root/Tools/ExtensionsLab/host-smoke.swift" \
  -o "$task_app/Contents/MacOS/HostSmoke"
codesign --force --sign - "$task_app" >/dev/null 2>&1
"$task_app/Contents/MacOS/HostSmoke" --out "$task_report" --work "$task_fixture/work"
