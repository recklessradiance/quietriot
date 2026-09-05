#!/bin/bash
# Builds the quietriotctl Activator tweak dylib (armv7, iOS 6.1.3).
# Plain clang build (no Logos needed - the tweak only registers Activator
# listeners via NSClassFromString, so a dynamiclib is all we need).
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${THEOS_SDK:-$HOME/theos/sdks/iPhoneOS10.3.sdk}"
CLANG="${CLANG:-/usr/bin/clang}"
OUT="$ROOT/.theos/obj/quietriotctl.dylib"

mkdir -p "$(dirname "$OUT")"

"$CLANG" -arch armv7 -miphoneos-version-min=6.1.3 -isysroot "$SDK" \
  -fno-modules -Wno-deprecated-declarations -Wall \
  -dynamiclib -o "$OUT" \
  "$ROOT/Tweak/Tweak.m" \
  -framework Foundation -framework UIKit -framework CoreFoundation \
  -L"$SDK/usr/lib" -lgcc_s.1 \
  -Wl,-dead_strip

ldid -S "$OUT"
echo "built $OUT"
