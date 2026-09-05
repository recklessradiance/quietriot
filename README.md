# quietriot

Live **audio-only** (mic) streamer for a jailbroken iPhone 4s (iOS 6.1.3, armv7),
with an optional camera HLS mode.

A single daemon (`quietriotd`) runs on the phone. Default mode is mic-only:

- captures the mic (AVCaptureAudioDataOutput, 44.1kHz mono s16le, ~23ms chunks)
- fans raw PCM out over a WebSocket (`/ws/audio`) straight from the capture queue
- a Web Audio page at `http://<phone-ip>:8080/` plays it with ~120-180ms latency

`--video` restores the original camera+mic HLS pipeline:

- captures rear/front camera (AVCaptureSession, 480x360, ~15fps) + mic
- pipes raw NV12 video + s16le PCM into an on-device `ffmpeg` (cross-compiled, x264 ultrafast + AAC)
- ffmpeg writes an HLS playlist + 1-second MPEG-TS segments
- the same daemon serves the HLS files and a control web page over HTTP
- ~3-4s latency (HLS floor; GOP = 1s)

## Start/stop from the phone (Notification Center widget)

The `QuietRiot` WeeApp (`NC/QuietRiotWeeApp.m`) is a Notification Center widget
(`/Library/WeeAppPlugins/QuietRiot.bundle`, BBWeeAppController protocol) that
shows a status label plus **Start** and **Stop** buttons below the weather
widget (drag to reorder in Settings -> Notifications):

- **Start**: if the daemon is down, spawns `quietriotd` (mic streaming starts
  immediately, as the mobile user); if it is up, turns streaming on (`/start`)
- **Stop**: asks the daemon to exit (`/shutdown`: kills ffmpeg, stops capture)
  and `killall`s any leftovers - the process is gone afterwards
- the status label refreshes whenever NC opens

The daemon is not always-on by design: widgets/buttons control the process.
(`deploy.sh` leaves it running after a deploy; `/shutdown` or the Stop button
kills it. A reboot starts nothing - use the widget.)

## Layout

```
Makefile                  theos build for quietriotd (armv7, min iOS 6.1.3)
src/                      daemon sources (ObjC/C)
web/index.html            video control page (ES5, native HLS + hls.js)  (--video)
web/audio.html            low-latency audio page (Web Audio + WebSocket)
NC/QuietRiotWeeApp.m      Notification Center widget (Start/Stop buttons)
tool/build-x264-ffmpeg.sh cross-compiles x264 + ffmpeg for armv7 iOS 6.1.3
tool/build-weeapp.sh      builds the NC widget bundle
tool/deploy.sh            installs binaries/config onto the phone over SSH
control/*.plist           launchd daemon definition
```

## Build (on the Mac)

Requirements: theos at `~/theos` with `sdks/iPhoneOS10.3.sdk` (no full Xcode
needed - the current Command Line Tools clang still emits armv7).

```sh
export THEOS=/Users/<you>/theos
make                      # builds .theos/obj/debug/armv7/quietriotd (armv7)
tool/build-weeapp.sh      # builds .theos/obj/QuietRiot.bundle (NC widget)
tool/build-x264-ffmpeg.sh # builds tool/prefix/bin/ffmpeg (armv7, static)  [--video only]
```


## Device setup (jailbroken 4s, iOS 6.1.3)

Via Cydia: install **OpenSSH**. Default `root` / `alpine`.

## Deploy

```sh
tool/deploy.sh 192.168.x.x          # builds, installs daemon + ffmpeg + web + NC widget, restarts, resprings
tool/deploy.sh 192.168.x.x logs     # tail daemon + ffmpeg logs
tool/deploy.sh 192.168.x.x stop     # stop the daemon
tool/deploy.sh 192.168.x.x shell    # interactive ssh
```

What it does: fake-signs the binaries with `ldid -S` (camera/mic access from a
CLI daemon needs a valid signature; no Apple developer account required),
installs `quietriotd` + `quietriot-ffmpeg` into `/usr/local/bin`, the web pages
into `/var/mobile/Library/quietriot/web`, the NC widget bundle into
`/Library/WeeAppPlugins/QuietRiot.bundle`, and the launchd plist into
`/Library/LaunchDaemons`. It then restarts the daemon (nohup fallback -
launchctl over non-interactive SSH fails; see gotchas), smoke-tests
`/status` + the audio page, and respings SpringBoard so the widget picks up.
The daemon is left **running** after a deploy.

Run it manually while debugging (default = audio-only; add `--video` for the
camera pipeline):

```sh
ssh root@<phone-ip> "quietriotd --port 8080 --logfile /var/mobile/Library/quietriot/daemon.log"
```

## Flags

```
--port N          HTTP port (default 8080)
--video           camera+mic HLS mode (default is mic-only WebSocket PCM)
--camera rear|front     [--video]
--fps N           default 15  [--video]
--workdir PATH    default /var/mobile/Library/quietriot
--ffmpeg PATH     default /usr/local/bin/quietriot-ffmpeg  [--video]
--logfile PATH    redirect daemon stdout/stderr to this file
--video-bitrate K default 400  [--video]
--audio-bitrate K default 64   [--video]
--audio-gain DB   mic boost in dB, default 18 (the 4s mic is very quiet)
```

Audio-only latency: capture chunks are ~23ms; the client schedules with
~100ms jitter buffer, so expect ~120-180ms glass-to-glass. Video mode:
x264 GOP = 1s (`-g = fps`), HLS segments cut at ~1s (`hls_time 1`,
list size 3) → ~3-4s glass-to-glass.

## Notes

- All APIs used are iOS 6-era (the 10.3 SDK is only used to compile; nothing
  iOS 7+ is called at runtime).
- The HTTP server hand-rolls RFC6455 WebSocket upgrade (SHA1 + base64 accept
  key) and broadcasts 16-bit PCM frames; slow clients are dropped, never
  allowed to block the capture queue.
- `--video` mode needs `libx264` (GPL); keep the ffmpeg build script's output private.
- If the A5 can't keep up in video mode, drop to 320x240 by changing the
  session preset in `src/CaptureEngine.mm` and rebuilding.

## Device gotchas (learned on the 4s / iOS 6.1.3)

- `launchctl` over non-interactive SSH fails with `launch_msg(): Socket is not
  connected`. The LaunchDaemon plist still works at boot (RunAtLoad is false,
  so nothing autostarts); run the daemon with nohup instead (what
  `tool/deploy.sh` does), or start it from the NC widget.
- iOS 6.1.3 has no `ps`, no `pgrep`, no `plutil`, no `awk`; use `killall` and
  `launchctl list`.
- `scp -r` to a not-yet-existing remote directory fails ("path canonicalization
  failed" - OpenSSH 6.7 sftp) on iOS 6: `ssh mkdir -p` the directory first,
  then scp files individually (that's how the widget bundle is installed).
- iOS 5/6 Notification Center widgets are "WeeApps": bundles under
  `/Library/WeeAppPlugins/<Name>.bundle` implementing the BBWeeAppController
  protocol (see `NC/QuietRiotWeeApp.m`). Enable/reorder them in Settings ->
  Notifications. Install/remove/respring SpringBoard to refresh.
- On the Mac, use `/usr/bin/curl` (the brew curl on this machine is a broken
  foreign-arch install) and quote URLs containing `?`.
- The A5's mic is quiet; `--audio-gain` (default 18 dB) feeds
  `volume` + `alimiter` in the ffmpeg/capture chain.
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
