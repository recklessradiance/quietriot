#!/bin/bash
# Deploys quietriotd + ffmpeg + web page + launchd plist to the iPhone over SSH.
# usage:
#   tool/deploy.sh <device-ip>              install + (re)start daemon
#   tool/deploy.sh <device-ip> stop         stop daemon
#   tool/deploy.sh <device-ip> logs         tail daemon + ffmpeg logs
#   tool/deploy.sh <device-ip> shell        just open a shell
set -e

IP="$1"
ACTION="${2:-install}"
[ -z "$IP" ] && { echo "usage: tool/deploy.sh <device-ip> [install|stop|logs|shell]" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh root@$IP"
SCP="scp -q"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

case "$ACTION" in
  shell) exec $SSH ;;
  logs)  exec $SSH "tail -n 40 -f /var/log/quietriotd.log" ;;
esac

# build fresh daemon binary
say "building quietriotd"
(cd "$ROOT" && env THEOS="${THEOS:-$HOME/theos}" make -s) \
  || { echo "make failed" >&2; exit 1; }

BIN="$ROOT/.theos/obj/debug/armv7/quietriotd"
FF="$ROOT/tool/prefix/bin/ffmpeg"
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
[ -x "$FF" ] || { echo "ffmpeg missing - run tool/build-x264-ffmpeg.sh first" >&2; exit 1; }

say "fake-signing binaries (ldid -S)"
ldid -S "$BIN"
ldid -S "$FF"

say "installing on device ($IP)"
$SSH "mkdir -p /usr/local/bin /var/mobile/Library/quietriot/web /var/mobile/Library/quietriot/hls"
$SCP "$BIN" root@$IP:/usr/local/bin/quietriotd
$SCP "$FF"  root@$IP:/usr/local/bin/quietriot-ffmpeg
$SCP "$ROOT/web/index.html" root@$IP:/var/mobile/Library/quietriot/web/index.html
[ -f "$ROOT/web/hls.min.js" ] && \
  $SCP "$ROOT/web/hls.min.js" root@$IP:/var/mobile/Library/quietriot/web/hls.min.js
$SCP "$ROOT/control/com.quietriot.daemon.plist" root@$IP:/Library/LaunchDaemons/com.quietriot.daemon.plist
$SSH "chown root:wheel /usr/local/bin/quietriotd /usr/local/bin/quietriot-ffmpeg && \
      chmod 755 /usr/local/bin/quietriotd /usr/local/bin/quietriot-ffmpeg && \
      chown root:wheel /Library/LaunchDaemons/com.quietriot.daemon.plist"

say "(re)starting daemon"
$SSH "launchctl unload /Library/LaunchDaemons/com.quietriot.daemon.plist 2>/dev/null; \
      rm -f /var/mobile/Library/quietriot/video.fifo /var/mobile/Library/quietriot/audio.fifo; \
      launchctl load /Library/LaunchDaemons/com.quietriot.daemon.plist"

sleep 2
say "status"
$SSH "launchctl list | grep quietriot || true; \
      tail -n 8 /var/log/quietriotd.log 2>/dev/null || true"
say "open http://$IP:8080/ to watch"
