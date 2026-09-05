# quietriot

Live camera + microphone streamer for a jailbroken iPhone 4s (iOS 6.1.3, armv7).

A single daemon (`quietriotd`) runs on the phone:

- captures the rear or front camera (AVCaptureSession, 480x360 preset, ~15fps) and mic audio
- pipes raw NV12 video + s16le PCM into an on-device `ffmpeg` (cross-compiled, x264 ultrafast + AAC)
- ffmpeg writes an HLS playlist + 1-second MPEG-TS segments
- the same daemon serves the HLS files and a control web page over HTTP

Watch it from any browser:
- iOS Safari (native HLS) and any modern desktop browser (hls.js fallback) at `http://<phone-ip>:8080/`
- switch front/rear camera live from the control page (`/switch?c=front|rear`)

Expected latency: ~4-10 seconds (HLS floor on iOS 6-era Safari). The A5 encodes
H.264 in software only, so 480x360 @ 15fps is the practical ceiling.

## Layout

```
Makefile                  theos build for quietriotd (armv7, min iOS 6.1.3)
src/                      daemon sources (ObjC/C)
web/index.html            control page (ES5, native HLS + hls.js fallback)
tool/build-x264-ffmpeg.sh cross-compiles x264 + ffmpeg for armv7 iOS 6.1.3
tool/deploy.sh            installs binaries/config onto the phone over SSH
control/*.plist           launchd daemon definition
```

## Build (on the Mac)

Requirements: theos at `~/theos` with `sdks/iPhoneOS10.3.sdk` (no full Xcode
needed - the current Command Line Tools clang still emits armv7).

```sh
export THEOS=/Users/<you>/theos
make                      # builds build/quietriotd (armv7)
tool/build-x264-ffmpeg.sh # builds tool/prefix/bin/ffmpeg (armv7, static)
```

## Device setup (jailbroken 4s, iOS 6.1.3)

Via Cydia: install **OpenSSH**. Default `root` / `alpine`.

## Deploy

```sh
tool/deploy.sh 192.168.x.x          # installs daemon + ffmpeg + web + tweak, restarts, resprings
tool/deploy.sh 192.168.x.x logs     # tail daemon + ffmpeg logs
tool/deploy.sh 192.168.x.x stop     # stop daemon
```

The daemon runs as root via launchd (`/Library/LaunchDaemons/com.quietriot.daemon.plist`);
`deploy.sh` also falls back to a `nohup` start (launchctl over non-interactive SSH
fails; see gotchas). It installs the Activator tweak into
`/Library/MobileSubstrate/DynamicLibraries/` and respings SpringBoard at the end.
Both binaries are fake-signed with `ldid -S` before upload (camera access from a
CLI daemon needs a valid signature; no Apple developer account required).

Run it manually while debugging:

```sh
ssh root@<phone-ip> "quietriotd --port 8080 --camera rear --logfile /var/mobile/Library/quietriot/daemon.log"
```

## Start/stop from the phone (Activator)

The `quietriotctl` tweak (source: `Tweak/Tweak.m`, built by
`tool/build-tweak.sh`, loaded into SpringBoard only) registers three Activator
actions after a respring: **QuietRiot: Toggle / Start / Stop stream**. Assign
them to any gesture in the Activator settings app.

- The tweak is privilege-free: it just `GET`s `http://127.0.0.1:8080/toggle`
  (plus `/start`, `/stop`) on localhost.
- If the daemon is not running, the toggle/start actions spawn it as the
  mobile user (all daemon state lives under `/var/mobile/Library/quietriot`,
  and iOS 6 has no camera TCC prompts), so gestures work even with the daemon
  dead.
- Feedback: a small alert shows `Streaming ON/OFF`.
- The web page has the same Start/Stop button (`/toggle`), and `/status`
  reports a `streaming` flag.
- Note: `deploy.sh`/root `killall` can stop even a SpringBoard-spawned (mobile)
  daemon; after a reboot the launchd plist starts the root instance again.

## Flags

```
--port N          HTTP port (default 8080)
--camera rear|front
--fps N           default 15
--workdir PATH    default /var/mobile/Library/quietriot
--ffmpeg PATH     default /usr/local/bin/quietriot-ffmpeg
--logfile PATH    redirect daemon stdout/stderr to this file
--video-bitrate K default 400
--audio-bitrate K default 64
```

## Notes

- All APIs used are iOS 6-era (the 10.3 SDK is only used to compile; nothing
  iOS 7+ is called at runtime).
- `ffmpeg` needs `libx264` (GPL); keep the ffmpeg build script's output private.
- If the A5 can't keep up, drop to 320x240 by changing the session preset in
  `src/CaptureEngine.mm` and rebuilding.

## Device gotchas (learned on the 4s / iOS 6.1.3)

- `launchctl` over non-interactive SSH fails with `launch_msg(): Socket is not
  connected`. The LaunchDaemon plist still works: it loads on next reboot, or
  run the daemon directly with nohup (as `tool/deploy.sh` falls back to).
- iOS 6.1.3 has no `ps`, no `plutil`, no `awk`; use `killall` and
  `launchctl list`.
- AVFoundation will NOT deliver sample buffers unless the main CFRunLoop is
  serviced — `dispatch_main()` alone is not enough. See `main.mm`.
- `poll()` on fifos never reports POLLOUT here; `qr_fifo_write` uses
  blocking-with-fcntl-fallback instead (never abandon a frame mid-write —
  rawvideo reads fixed-size blocks and mid-frame drops desync the stream).
- x264 without NEON encodes ~1 fps at 480x360. The build script builds NEON
  asm via `tool/gas-preprocessor.pl` (patched for `.data.rel.ro`); expect
  realtime 15 fps with it.
- The theos iPhoneOS10.3.sdk `libobjc.tbd` is trimmed and lacks
  `_objc_msgSend_stret`; it was patched in place (struct-returning properties
  like `CMTime` need it). The on-device dylib has it.
- Legacy iOS 6 OpenSSH only: `ssh-copy-id`/`sshpass` work; OpenSSH 6.7 server.
- On the Mac, brew's `/usr/local/bin/curl` is a broken foreign-arch binary —
  always use `/usr/bin/curl`.
