#!/bin/bash
# Builds the Notification Center WeeApp bundle (QuietRiot start/stop widget).
# Output: .theos/obj/QuietRiot.bundle
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLANG="${CLANG:-/usr/bin/clang}"
SDK="${THEOS_SDK:-$HOME/theos/sdks/iPhoneOS10.3.sdk}"
OUT="$ROOT/.theos/obj"

mkdir -p "$OUT"
"$CLANG" -arch armv7 -miphoneos-version-min=6.1.3 -isysroot "$SDK" \
  -fno-modules -Wno-deprecated-declarations -Wall \
  -bundle "$ROOT/NC/QuietRiotWeeApp.m" -o "$OUT/QuietRiotWeeApp" \
  -framework Foundation -framework UIKit -framework CoreFoundation \
  -lgcc_s.1 -Wl,-dead_strip

ldid -S "$OUT/QuietRiotWeeApp"

rm -rf "$OUT/QuietRiot.bundle"
mkdir -p "$OUT/QuietRiot.bundle"
cp "$OUT/QuietRiotWeeApp" "$OUT/QuietRiot.bundle/QuietRiotWeeApp"
cp "$ROOT/NC/Info.plist" "$OUT/QuietRiot.bundle/Info.plist"
chmod 755 "$OUT/QuietRiot.bundle/QuietRiotWeeApp"

echo "built $OUT/QuietRiot.bundle"
