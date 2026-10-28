#!/bin/bash
# Explicit network operation: submit a Developer ID-signed app or DMG to Apple.
set -euo pipefail

target=
kind=
profile=${NOTARY_KEYCHAIN_PROFILE:-${NOTARYTOOL_PROFILE:-}}
usage() {
  cat <<'HELP'
Usage: Tools/Release/notarize.sh --app PATH --keychain-profile NAME
       Tools/Release/notarize.sh --dmg PATH --keychain-profile NAME

Submits to Apple, waits for an Accepted result, staples and validates the ticket.
Create the named profile separately with xcrun notarytool store-credentials.
Credentials are read from Keychain and are never written into this repository.
NOTARY_KEYCHAIN_PROFILE may provide the profile name instead of the flag.
HELP
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--dmg)
      [ "$#" -ge 2 ] && [ -z "$target" ] || { usage >&2; exit 2; }
      kind=${1#--}; target=$2; shift 2 ;;
    --keychain-profile)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      profile=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$target" ] && [ -n "$profile" ] && [ -e "$target" ] || { usage >&2; exit 2; }
target=$(cd "$(dirname "$target")" && pwd)/$(basename "$target")
codesign --verify --deep --strict "$target"
signature=$(codesign --display --verbose=4 "$target" 2>&1)
printf '%s\n' "$signature" | grep -q '^Authority=Developer ID Application:' || {
  printf 'A Developer ID Application signature is required before notarization.\n' >&2; exit 1;
}
if [ "$kind" = app ]; then
  printf '%s\n' "$signature" | grep -q 'flags=.*runtime' || {
    printf 'The app must be signed with hardened runtime.\n' >&2; exit 1;
  }
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/feather-notarize.XXXXXX")
trap 'rm -rf "$work"' EXIT
submission=$target
if [ "$kind" = app ]; then
  submission="$work/Feather.zip"
  ditto -c -k --keepParent "$target" "$submission"
fi
report="${target%.*}-notarization.json"
xcrun notarytool submit "$submission" --keychain-profile "$profile" \
  --wait --output-format json > "$report"
python3 - "$report" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
if report.get("status") != "Accepted":
    raise SystemExit("Apple did not accept the submission. Inspect " + sys.argv[1])
PY
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [ "$kind" = app ]; then
  spctl --assess --type execute --verbose=2 "$target"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi
printf 'Notarization accepted and stapled: %s\nReport: %s\n' "$target" "$report"
