#!/bin/bash
# Deploys quietriotd + ffmpeg + web page + launchd plist + Activator tweak
# to the iPhone over SSH.
# usage:
#   tool/deploy.sh <device-ip>              install + (re)start daemon + respring
#   tool/deploy.sh <device-ip> stop         stop daemon
#   tool/deploy.sh <device-ip> logs         tail daemon + ffmpeg logs
#   tool/deploy.sh <device-ip> shell        just open a shell
# NOTE: use /usr/bin/curl on this Mac (brew curl is foreign-arch broken).
set -e

IP="$1"
ACTION="${2:-install}"
[ -z "$IP" ] && { echo "usage: tool/deploy.sh <device-ip> [install|stop|logs|shell]" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -o ConnectTimeout=10 root@$IP"
SCP="scp -q"
WORK="/var/mobile/Library/quietriot"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

case "$ACTION" in
  shell) exec $SSH ;;
  logs)  exec $SSH "tail -n 40 -f $WORK/daemon.log $WORK/ffmpeg.log 2>/dev/null" ;;
esac

# build fresh daemon binary + activator tweak
say "building quietriotd + tweak"
(cd "$ROOT" && env THEOS="${THEOS:-$HOME/theos}" make -s) \
  || { echo "make failed" >&2; exit 1; }
"$ROOT/tool/build-tweak.sh"

BIN="$ROOT/.theos/obj/debug/armv7/quietriotd"
FF="$ROOT/tool/prefix/bin/ffmpeg"
TWEAK="$ROOT/.theos/obj/quietriotctl.dylib"
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
[ -x "$FF" ] || { echo "ffmpeg missing - run tool/build-x264-ffmpeg.sh first" >&2; exit 1; }
[ -f "$TWEAK" ] || { echo "missing $TWEAK" >&2; exit 1; }

say "fake-signing binaries (ldid -S)"
ldid -S "$BIN"
ldid -S "$FF"

say "installing on device ($IP)"
$SSH "mkdir -p /usr/local/bin $WORK/web $WORK/hls /Library/MobileSubstrate/DynamicLibraries"
$SCP "$BIN" root@$IP:/usr/local/bin/quietriotd
$SCP "$FF"  root@$IP:/usr/local/bin/quietriot-ffmpeg
$SCP "$TWEAK" root@$IP:/Library/MobileSubstrate/DynamicLibraries/quietriotctl.dylib
$SCP "$ROOT/control/quietriotctl.plist" \
     root@$IP:/Library/MobileSubstrate/DynamicLibraries/quietriotctl.plist
$SCP "$ROOT/web/index.html" root@$IP:$WORK/web/index.html
[ -f "$ROOT/web/hls.min.js" ] && \
  $SCP "$ROOT/web/hls.min.js" root@$IP:$WORK/web/hls.min.js
$SCP "$ROOT/control/com.quietriot.daemon.plist" root@$IP:/Library/LaunchDaemons/com.quietriot.daemon.plist
$SSH "chown root:wheel /usr/local/bin/quietriotd /usr/local/bin/quietriot-ffmpeg && \
      chmod 755 /usr/local/bin/quietriotd /usr/local/bin/quietriot-ffmpeg && \
      chown root:wheel /Library/MobileSubstrate/DynamicLibraries/quietriotctl.dylib && \
      chmod 755 /Library/MobileSubstrate/DynamicLibraries/quietriotctl.dylib && \
      chown root:wheel /Library/MobileSubstrate/DynamicLibraries/quietriotctl.plist && \
      chmod 644 /Library/MobileSubstrate/DynamicLibraries/quietriotctl.plist && \
      chown root:wheel /Library/LaunchDaemons/com.quietriot.daemon.plist"

say "(re)starting daemon"
# unload first so launchd KeepAlive cannot respawn the old binary mid-swap
$SSH "launchctl unload /Library/LaunchDaemons/com.quietriot.daemon.plist 2>/dev/null; \
      killall quietriotd 2>/dev/null; sleep 1; \
      rm -f $WORK/video.fifo $WORK/audio.fifo; \
      nohup /usr/local/bin/quietriotd --port 8080 --camera rear --logfile $WORK/daemon.log \
            </dev/null >/dev/null 2>&1 &"
sleep 2

say "smoke test (from Mac)"
/usr/bin/curl -m 5 -s "http://$IP:8080/status" || echo "(status not reachable yet)"
echo
/usr/bin/curl -m 5 -s "http://$IP:8080/toggle" || true
sleep 2
/usr/bin/curl -m 5 -s "http://$IP:8080/toggle" || true
echo

say "installing tweak -> respring"
$SSH "killall SpringBoard" || true

say "done"
say "open http://$IP:8080/ to watch; assign gestures in Activator -> QuietRiot"
