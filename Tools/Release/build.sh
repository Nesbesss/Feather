#!/bin/bash
# Build a release candidate without changing the installed Feather or its profile.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
version=0.1.0
build_number=1
architecture=universal
output_dir="$root/build/release"

usage() {
  cat <<'HELP'
Usage: Tools/Release/build.sh [--version 0.1.0] [--build 1]
                            [--arch universal|arm64|x86_64] [--output-dir PATH]

Outputs Feather.app and build.log. Defaults to an ad-hoc preview signature.
Set DEVELOPER_ID_APPLICATION to an installed Developer ID Application identity
to sign with hardened runtime for a subsequent explicit notarize.sh invocation.
DEVELOPER_DIR can select Xcode for this command without changing xcode-select.
HELP
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--build|--arch|--output-dir)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --version) version=$2 ;;
        --build) build_number=$2 ;;
        --arch) architecture=$2 ;;
        --output-dir) output_dir=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Version must contain three numeric components, for example 0.1.0.\n' >&2; exit 2;
}
[[ "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || {
  printf 'Build must contain one to three numeric components.\n' >&2; exit 2;
}
case "$architecture" in
  universal) archs='arm64 x86_64' ;;
  arm64|x86_64) archs=$architecture ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac

command -v xcodegen >/dev/null || { printf 'Install XcodeGen: brew install xcodegen\n' >&2; exit 1; }
xcodebuild -version >/dev/null || { printf 'Select a full Xcode using DEVELOPER_DIR.\n' >&2; exit 1; }
for legal_file in LICENSE THIRD_PARTY_NOTICES.md; do
  [ -f "$root/$legal_file" ] || {
    printf 'Missing release legal notice: %s\n' "$legal_file" >&2; exit 1;
  }
done
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
log="$output_dir/build.log"
derived_data="$output_dir/DerivedData"
app="$output_dir/Feather.app"
source_manifest="$output_dir/BUILD-SOURCE.json"
cd "$root"
python3 "$root/Tools/Release/build-source.py" capture --output "$source_manifest"
xcodegen generate --spec project.yml 2>&1 | tee "$log"

# Ignore personal signing/provisioning overrides when constructing this candidate.
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
  "ARCHS=$archs" ONLY_ACTIVE_ARCH=NO \
  "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build_number" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER= \
  build 2>&1 | tee -a "$log"

built_app="$derived_data/Build/Products/Release/Feather.app"
[ -d "$built_app" ] || { printf 'Build did not produce Feather.app.\n' >&2; exit 1; }
for required_arch in $archs; do
  lipo -verify_arch "$required_arch" "$built_app/Contents/MacOS/Feather"
done

# Stage before replacing a prior candidate to avoid a partially copied app.
staged_app="$output_dir/.Feather-staging-$$.app"
trap 'rm -rf "$staged_app"' EXIT
ditto "$built_app" "$staged_app"
mkdir -p "$staged_app/Contents/Resources/Legal"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$staged_app/Contents/Resources/Legal/"
# Fail if app code, resources, public build settings or build tools changed while
# Xcode ran. Embed this exact input snapshot before creating the app signature.
python3 "$root/Tools/Release/build-source.py" verify --manifest "$source_manifest"
cp "$source_manifest" "$staged_app/Contents/Resources/Legal/BUILD-SOURCE.json"
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$staged_app"
  codesign --display --verbose=4 "$staged_app" 2>&1 | grep -q '^Authority=Developer ID Application:' || {
    printf 'Signing identity is not a Developer ID Application certificate.\n' >&2; exit 1;
  }
else
  codesign --force --timestamp=none --sign - "$staged_app"
fi
codesign --verify --deep --strict --verbose=2 "$staged_app"
rm -rf "$app"
mv "$staged_app" "$app"
printf '\nBuilt %s (%s), architectures: %s\nApp: %s\nLog: %s\n' \
  "$version" "$build_number" "$archs" "$app" "$log"
if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
  printf 'Preview signature only; this app is not notarized for public distribution.\n'
fi
