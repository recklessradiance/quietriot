#!/bin/bash
# Builds an installable Cydia .deb package for quietriot.
#
# usage:
#   tool/build-deb.sh            build daemon + weeapp (+ ffmpeg if missing), then package
#   tool/build-deb.sh --no-ffmpeg  package without bundling the GPL ffmpeg binary
#
# Output: dist/quietriot_<version>_iphoneos-arm.deb
#
# Install on device:  dpkg -i <file>   (over ssh or via Filza)
# Host a repo:        tool/build-repo.sh (see that script) or drop the .deb
#                     in any file repo and add it in Cydia.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/.theos/deb-payload"
DIST="$ROOT/dist"
NO_FFMPEG=0
[ "$1" = "--no-ffmpeg" ] && NO_FFMPEG=1

PKG=quietriot
VERSION=1.0.0
ARCH=iphoneos-arm
WORK=/var/mobile/Library/quietriot

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# -----------------------------
# Build artifacts
# -----------------------------

say "building quietriotd + weeapp"
(cd "$ROOT" && env THEOS="${THEOS:-$HOME/theos}" make -s) \
  || { echo "make failed" >&2; exit 1; }
"$ROOT/tool/build-weeapp.sh"

BIN="$ROOT/.theos/obj/debug/armv7/quietriotd"
BUNDLE="$ROOT/.theos/obj/QuietRiot.bundle"
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
[ -x "$BUNDLE/QuietRiotWeeApp" ] || { echo "missing weeapp binary" >&2; exit 1; }

FF="$ROOT/tool/prefix/bin/ffmpeg"
if [ "$NO_FFMPEG" = 0 ] && [ ! -x "$FF" ]; then
  say "ffmpeg missing - running tool/build-x264-ffmpeg.sh (skip with --no-ffmpeg)"
  "$ROOT/tool/build-x264-ffmpeg.sh"
fi
if [ "$NO_FFMPEG" = 0 ]; then
  [ -x "$FF" ] || { echo "ffmpeg still missing" >&2; exit 1; }
fi

# -----------------------------
# Fake-sign (camera/mic access needs a valid signature)
# -----------------------------

say "fake-signing binaries (ldid -S)"
ldid -S "$BIN"
ldid -S "$BUNDLE/QuietRiotWeeApp"
[ "$NO_FFMPEG" = 0 ] && ldid -S "$FF"

# -----------------------------
# Assemble payload
# -----------------------------

say "staging payload"
rm -rf "$STAGE"
mkdir -p \
  "$STAGE/DEBIAN" \
  "$STAGE/usr/local/bin" \
  "$STAGE/Library/LaunchDaemons" \
  "$STAGE/Library/WeeAppPlugins/QuietRiot.bundle" \
  "$STAGE$WORK/web"

cp "$BIN" "$STAGE/usr/local/bin/quietriotd"
[ "$NO_FFMPEG" = 0 ] && cp "$FF" "$STAGE/usr/local/bin/quietriot-ffmpeg"
cp "$ROOT/control/com.quietriot.daemon.plist" \
   "$STAGE/Library/LaunchDaemons/com.quietriot.daemon.plist"

cp "$BUNDLE/QuietRiotWeeApp" "$BUNDLE/Info.plist" \
   "$STAGE/Library/WeeAppPlugins/QuietRiot.bundle/"
cp "$ROOT/web/index.html" "$ROOT/web/audio.html" "$STAGE$WORK/web/"
[ -f "$ROOT/web/hls.min.js" ] && \
  cp "$ROOT/web/hls.min.js" "$STAGE$WORK/web/"

chmod 755 "$STAGE/usr/local/bin/quietriotd"
[ -f "$STAGE/usr/local/bin/quietriot-ffmpeg" ] && \
  chmod 755 "$STAGE/usr/local/bin/quietriot-ffmpeg"
chmod 755 "$STAGE/Library/WeeAppPlugins/QuietRiot.bundle/QuietRiotWeeApp"

# -----------------------------
# DEBIAN control + maintainer scripts
# -----------------------------

SIZE_KB=$(du -sk "$STAGE" | cut -f1)
INSTALLED_SIZE=$((SIZE_KB))

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Name: QuietRiot
Version: $VERSION
Architecture: $ARCH
Maintainer: rcred
Author: rcred
Installed-Size: $INSTALLED_SIZE
Depends: firmware (>= 6.0)
Description: Live mic streamer daemon + Notification Center widget
 QuietRiot runs quietriotd, a low-latency mic-only audio streamer
 (WebSocket PCM, Web Audio page) on jailbroken iOS 6.1.3, with an
 optional camera+mic HLS mode (--video). Includes a Notification
 Center widget to start/stop the daemon from the phone.
EOF

# preinst: stop any running daemon so files can be replaced
cat > "$STAGE/DEBIAN/preinst" <<'EOF'
#!/bin/bash
killall -9 quietriotd quietriot-ffmpeg 2>/dev/null
exit 0
EOF

# prerm: stop daemon, drop the LaunchDaemon so boot autostart is gone
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/bash
launchctl unload /Library/LaunchDaemons/com.quietriot.daemon.plist 2>/dev/null
killall -9 quietriotd quietriot-ffmpeg 2>/dev/null
exit 0
EOF

# postrm: remove daemon data dir + widget leftovers, respring
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/bash
rm -rf /var/mobile/Library/quietriot
rm -rf /Library/WeeAppPlugins/QuietRiot.bundle 2>/dev/null
killall SpringBoard 2>/dev/null
exit 0
EOF

# postinst: fix perms/owners, refresh launchd, respring so the NC widget loads
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/bash
chown root:wheel /usr/local/bin/quietriotd 2>/dev/null
chmod 755 /usr/local/bin/quietriotd
if [ -f /usr/local/bin/quietriot-ffmpeg ]; then
  chown root:wheel /usr/local/bin/quietriot-ffmpeg 2>/dev/null
  chmod 755 /usr/local/bin/quietriot-ffmpeg
fi
chown root:wheel /Library/LaunchDaemons/com.quietriot.daemon.plist 2>/dev/null
chmod 644 /Library/LaunchDaemons/com.quietriot.daemon.plist
chown -R root:wheel /Library/WeeAppPlugins/QuietRiot.bundle 2>/dev/null
chown -R mobile:mobile /var/mobile/Library/quietriot 2>/dev/null
chmod -R 755 /var/mobile/Library/quietriot 2>/dev/null
launchctl load /Library/LaunchDaemons/com.quietriot.daemon.plist 2>/dev/null
killall SpringBoard 2>/dev/null
exit 0
EOF

chmod 755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/prerm" \
          "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# -----------------------------
# Package (gzip: iOS 6 dpkg cannot read xz-compressed debs)
# -----------------------------

mkdir -p "$DIST"
OUT="$DIST/${PKG}_${VERSION}_${ARCH}.deb"
say "packing $OUT"
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$OUT"

say "built $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Install over ssh:"
echo "  scp $OUT root@<phone-ip>:/var/mobile/Documents/ && ssh root@<phone-ip> dpkg -i /var/mobile/Documents/$(basename "$OUT")"
echo "Or open it in Filza on the phone."
