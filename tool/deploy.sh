#!/bin/bash
# Deploys quietriotd + ffmpeg + web pages + launchd plist + NC WeeApp widget
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

# build fresh daemon binary + NC widget bundle
say "building quietriotd + weeapp"
(cd "$ROOT" && env THEOS="${THEOS:-$HOME/theos}" make -s) \
  || { echo "make failed" >&2; exit 1; }
"$ROOT/tool/build-weeapp.sh"

BIN="$ROOT/.theos/obj/debug/armv7/quietriotd"
FF="$ROOT/tool/prefix/bin/ffmpeg"
BUNDLE="$ROOT/.theos/obj/QuietRiot.bundle"
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
[ -x "$FF" ] || { echo "ffmpeg missing - run tool/build-x264-ffmpeg.sh first" >&2; exit 1; }
[ -x "$BUNDLE/QuietRiotWeeApp" ] || { echo "missing weeapp binary" >&2; exit 1; }

say "fake-signing binaries (ldid -S)"
ldid -S "$BIN"
ldid -S "$FF"

say "installing on device ($IP)"
$SSH "mkdir -p /usr/local/bin $WORK/web $WORK/hls /Library/WeeAppPlugins"
$SCP "$BIN" root@$IP:/usr/local/bin/quietriotd
$SCP "$FF"  root@$IP:/usr/local/bin/quietriot-ffmpeg
$SCP "$ROOT/web/index.html" root@$IP:$WORK/web/index.html
$SCP "$ROOT/web/audio.html" root@$IP:$WORK/web/audio.html
[ -f "$ROOT/web/hls.min.js" ] && \
  $SCP "$ROOT/web/hls.min.js" root@$IP:$WORK/web/hls.min.js
$SCP "$ROOT/control/com.quietriot.daemon.plist" root@$IP:/Library/LaunchDaemons/com.quietriot.daemon.plist

# NC widget (replaces the old activator tweak); file-by-file scp: the old
# OpenSSH sftp-server on iOS 6 chokes on `scp -r` into a fresh dir
$SSH "rm -rf /Library/WeeAppPlugins/QuietRiot.bundle && \
      rm -f /Library/MobileSubstrate/DynamicLibraries/quietriotctl.dylib \
            /Library/MobileSubstrate/DynamicLibraries/quietriotctl.plist && \
      mkdir -p /Library/WeeAppPlugins/QuietRiot.bundle"
$SCP "$BUNDLE/QuietRiotWeeApp" root@$IP:/Library/WeeAppPlugins/QuietRiot.bundle/QuietRiotWeeApp
$SCP "$BUNDLE/Info.plist" root@$IP:/Library/WeeAppPlugins/QuietRiot.bundle/Info.plist
$SSH "chown -R root:wheel /Library/WeeAppPlugins/QuietRiot.bundle && \
      chmod 755 /Library/WeeAppPlugins/QuietRiot.bundle/QuietRiotWeeApp && \
      chown root:wheel /usr/local/bin/quietriotd /usr/local/bin/quietriot-ffmpeg && \
      chmod 755 /usr/local/bin/quietriotd /usr/local/bin/quietriot-ffmpeg && \
      chown root:wheel /Library/LaunchDaemons/com.quietriot.daemon.plist"

say "(re)starting daemon (mic-only, WebSocket PCM)"
# NC-widget Start spawns the daemon as the mobile user from SpringBoard, so
# the log files must be writable by mobile (freopen failure is silent).
$SSH "launchctl unload /Library/LaunchDaemons/com.quietriot.daemon.plist 2>/dev/null; \
      killall quietriotd 2>/dev/null; killall -9 quietriot-ffmpeg 2>/dev/null; sleep 1; \
      rm -f $WORK/video.fifo $WORK/audio.fifo; \
      touch $WORK/daemon.log $WORK/ffmpeg.log $WORK/widget.log; \
      chown mobile:mobile $WORK/daemon.log $WORK/ffmpeg.log $WORK/widget.log; \
      nohup /usr/local/bin/quietriotd --port 8080 --logfile $WORK/daemon.log \
            </dev/null >/dev/null 2>&1 &"
sleep 2

say "smoke test (from Mac)"
/usr/bin/curl -m 5 -s "http://$IP:8080/status" || echo "(status not reachable yet)"
echo
/usr/bin/curl -m 5 -s -o /dev/null -w "/audio page: %{http_code}\n" "http://$IP:8080/audio" || true

say "respringing SpringBoard (loads the QuietRiot NC widget)"
$SSH "killall SpringBoard" || true

say "done"
say "daemon left RUNNING; Control it from Notification Center (QuietRiot buttons), or /shutdown + killall"
say "listen at http://$IP:8080/ (tap Enable live audio)"
