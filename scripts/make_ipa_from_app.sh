#!/usr/bin/env bash
# Turn a built MotionForge.app into a sideloadable .ipa (works on macOS or Linux; needs only `zip`).
#
#   ./scripts/make_ipa_from_app.sh path/to/MotionForge.app [output.ipa]
#
# An .ipa is a zip whose only top-level entry is a folder named exactly `Payload`, containing the .app:
#   MotionForge.ipa
#   └── Payload/
#       └── MotionForge.app/   (executable, Info.plist, default.metallib, Assets.car, …)
set -euo pipefail

APP="${1:-}"
OUT="${2:-MotionForge-unsigned.ipa}"
[[ -n "$APP" && -d "$APP" && "$APP" == *.app ]] || { echo "Usage: $0 path/to/MotionForge.app [output.ipa]"; exit 1; }
[[ -f "$APP/Info.plist" ]] || { echo "Not an iOS app bundle: $APP/Info.plist is missing"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
rm -rf "$WORK/Payload/$(basename "$APP")/_CodeSignature" 2>/dev/null || true   # re-signing tools add their own

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && zip -qry "$OUT_ABS" Payload)

echo "Created: $OUT_ABS"
echo "Top level of the archive:"; unzip -Z1 "$OUT_ABS" | awk -F/ '{print $1"/"}' | sort -u
unzip -Z1 "$OUT_ABS" | grep -q "^Payload/$(basename "$APP")/Info.plist$" && echo "Structure OK: Payload/$(basename "$APP")/Info.plist found"
