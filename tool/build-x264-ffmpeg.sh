#!/bin/bash
# Cross-compiles x264 + ffmpeg for armv7 / iOS 6.1.3 using the Command Line
# Tools clang against the theos iPhoneOS10.3 SDK. Output: tool/prefix/bin/ffmpeg
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
SDK="$THEOS/sdks/iPhoneOS10.3.sdk"
CC="${CC:-/usr/bin/clang}"
MINVER="6.1.3"
ARCH="armv7"
PREFIX="$ROOT/tool/prefix"
JOBS="$(sysctl -n hw.ncpu)"

ARCHFLAGS="-arch $ARCH -miphoneos-version-min=$MINVER -isysroot $SDK"
# armv7 64/32-bit divide helpers (__divdi3, __divsi3) come from libgcc_s.1,
# which exists on iOS 6+ at /usr/lib/libgcc_s.1.dylib
GCCFIX="-lgcc_s.1"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[ -d "$SDK" ] || { echo "SDK not found: $SDK" >&2; exit 1; }
mkdir -p "$PREFIX"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# ---------------------------------------------------------------- x264
if [ -f "$PREFIX/lib/libx264.a" ] && [ "${REBUILD_X264:-0}" != "1" ]; then
    say "x264 already built: $PREFIX/lib/libx264.a"
else
say "building x264 (armv7, static)"
cd "$ROOT/vendor/x264"
( make distclean >/dev/null 2>&1 || true )

X264_DONE=0
# NEON: the A5 is a Cortex-A9; x264 NEON asm is ~8-10x faster than C.
# Apple clang can't assemble GNU-as syntax -> route .S files through
# gas-preprocessor.pl which translates them for clang's integrated as.
GASWRAP="$ROOT/tool/gas-x264-wrap.sh"
cat > "$GASWRAP" <<'EOF'
#!/bin/bash
# gas-preprocessor scans the command line for "-arch arm..." to pick the
# comment char; inject it since x264's ASFLAGS don't carry it.
exec perl /Users/rcred/Documents/Projects/quietriot/tool/gas-preprocessor.pl \
    /usr/bin/clang -arch armv7 -miphoneos-version-min=6.1.3 "$@"
EOF
chmod +x "$GASWRAP"

NEONFLAGS="-mfpu=neon -mcpu=cortex-a9"
# modern clang errors on old x264's asm fn-pointer assignments
WARNOFF="-Wno-incompatible-function-pointer-types"
for CFG in 0 1 2; do
    ( make distclean >/dev/null 2>&1 || true )
    AS_VAL=""
    EXTRA_CFLAGS="$WARNOFF"
    XCONF=""
    case $CFG in
        0) AS_VAL="$GASWRAP"; EXTRA_CFLAGS="$WARNOFF $NEONFLAGS";;
        1) AS_VAL="$GASWRAP";;
        2) XCONF="--disable-asm";;
    esac
    say "x264 attempt $CFG (asm flags: ${EXTRA_CFLAGS:-none})"
    if CC="$CC" AS="$AS_VAL" \
         CFLAGS="$ARCHFLAGS -O2 -Wno-implicit-function-declaration $EXTRA_CFLAGS" \
         LDFLAGS="$ARCHFLAGS" \
         ./configure --host=arm-apple-darwin \
                     --prefix="$PREFIX" \
                     --enable-static --disable-cli --disable-opencl $XCONF \
                     > "$ROOT/tool/x264-configure.log" 2>&1 \
       && make -j"$JOBS" > "$ROOT/tool/x264-build.log" 2>&1 \
       && make install > "$ROOT/tool/x264-install.log" 2>&1; then
        say "x264 built OK with config $CFG"
        X264_DONE=1
        break
    fi
    tail -8 "$ROOT/tool/x264-configure.log" || true
    tail -8 "$ROOT/tool/x264-build.log" || true
done
if [ "$X264_DONE" != "1" ]; then
    echo "all x264 build attempts failed" >&2
    exit 1
fi
fi
say "x264 installed: $(ls -la "$PREFIX/lib/libx264.a" 2>/dev/null || echo MISSING)"

# ---------------------------------------------------------------- ffmpeg
say "building ffmpeg 4.4.1 (armv7, static, linked with libx264)"
cd "$ROOT/vendor/ffmpeg-4.4.1"
( make distclean >/dev/null 2>&1 || true )

./configure \
    --enable-cross-compile --target-os=darwin --arch=arm --cpu=armv7 \
    --cc="$CC" \
    --extra-cflags="$ARCHFLAGS -O2 -Wno-implicit-function-declaration" \
    --extra-ldflags="$ARCHFLAGS $GCCFIX" \
    --prefix="$PREFIX" \
    --enable-gpl --enable-libx264 \
    --enable-static --disable-shared \
    --enable-ffmpeg --disable-ffprobe --disable-ffplay \
    --disable-doc --disable-debug \
    --disable-avdevice --disable-network \
    --disable-iconv --disable-bzlib --disable-lzma --disable-zlib \
    --disable-sdl2 --disable-xlib --disable-libxcb \
    --disable-vaapi --disable-vdpau --disable-vulkan --disable-opencl \
    --disable-videotoolbox \
    --enable-pthreads \
    > "$ROOT/tool/ffmpeg-configure.log" 2>&1 || {
        tail -30 "$ROOT/tool/ffmpeg-configure.log" >&2
        exit 1
    }
tail -3 "$ROOT/tool/ffmpeg-configure.log"

make -j"$JOBS" > "$ROOT/tool/ffmpeg-build.log" 2>&1 || {
    tail -40 "$ROOT/tool/ffmpeg-build.log" >&2
    exit 1
}
make install > "$ROOT/tool/ffmpeg-install.log" 2>&1

say "done: $PREFIX/bin/ffmpeg"
file "$PREFIX/bin/ffmpeg"
ls -la "$PREFIX/bin/ffmpeg"
