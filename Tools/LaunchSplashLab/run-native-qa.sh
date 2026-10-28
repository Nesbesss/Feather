#!/bin/zsh
set -euo pipefail
task_root=${0:A:h:h:h}
task_work=$(mktemp -d /tmp/feather-launch-splash.XXXXXX)
trap 'rm -rf "$task_work"' EXIT
task_app="$task_work/FeatherLaunchSplashQA.app"
task_output=${1:-"$task_root/Tools/LaunchSplashLab/results"}
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" "$task_output"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.nesbes.Feather.LaunchSplashQA</string><key>CFBundleName</key><string>Feather Launch Splash QA</string><key>CFBundleExecutable</key><string>LaunchSplashQA</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
xcrun actool "$task_root/Feather/Resources/Assets.xcassets" \
  --compile "$task_app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
  --target-device mac --app-icon AppIcon --output-partial-info-plist "$task_work/assets.plist" \
  --output-format human-readable-text >/dev/null
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  "$task_root/Feather/Welcome/LaunchSplashMotion.swift" \
  "$task_root/Feather/Welcome/LaunchSplashView.swift" \
  "$task_root/Feather/Welcome/LaunchSplashController.swift" \
  "$task_root/Tools/LaunchSplashLab/native-qa.swift" \
  -o "$task_app/Contents/MacOS/LaunchSplashQA"
codesign --force --sign - "$task_app" >/dev/null 2>&1
"$task_app/Contents/MacOS/LaunchSplashQA" "$task_root" "$task_output"
if command -v ffmpeg >/dev/null && [[ -d "$task_output/frames" ]]; then
  ffmpeg -y -loglevel error -framerate 60 -i "$task_output/frames/%04d.png" \
    -c:v libx264 -pix_fmt yuv420p -profile:v high -crf 20 -r 60 -movflags +faststart \
    "$task_output/feather-launch-preview.mp4"
  # Keep the shareable movie and proof stills; full-resolution intermediates
  # are regenerated on each run and need not fill the source checkout.
  rm -f "$task_output/frames"/[0-9][0-9][0-9][0-9].png
  rmdir "$task_output/frames" 2>/dev/null || true
fi
