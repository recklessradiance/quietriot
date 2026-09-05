#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "CaptureEngine.h"
#import "FfmpegProc.h"
#import "HttpServer.h"
#import "AudioHub.h"

#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

#define QR_LOG(...) fprintf(stderr, "[main] " __VA_ARGS__)

// set by FfmpegProc; kill the encoder on TERM so it never outlives us
extern volatile pid_t qr_ffmpeg_pid;

static void qr_terminate(int sig)
{
    (void)sig;
    pid_t p = qr_ffmpeg_pid;
    if (p > 0) kill(p, SIGKILL);
    _exit(0);
}

static void usage(void)
{
    fprintf(stderr,
        "quietriotd - live mic/camera streamer for jailbroken iOS 6.1.3\n"
        "default: mic-only WebSocket PCM (/audio page, ~150-250ms latency)\n"
        "usage: quietriotd [--port N] [--fps N] [--logfile PATH]\n"
        "                  [--video]  (camera+mic HLS pipeline, / = video page)\n"
        "                  [--audio-only]  (explicit, same as default)\n"
        "video mode only: [--camera rear|front] [--workdir PATH] [--ffmpeg PATH]\n"
        "                 [--video-bitrate K] [--audio-bitrate K] [--audio-gain DB]\n");
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = qr_terminate;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    int port = 8080, fps = 15, vb = 400, ab = 64, ag = 18;
    int videoMode = 0;   // default: mic-only WebSocket stream
    QRCamera initialCamera = QRCameraRear;
    NSString *workdir = @"/var/mobile/Library/quietriot";
    NSString *ffbin = @"/usr/local/bin/quietriot-ffmpeg";
    NSString *logfile = nil;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--port") == 0 && i + 1 < argc) port = atoi(argv[++i]);
        else if (strcmp(a, "--fps") == 0 && i + 1 < argc) fps = atoi(argv[++i]);
        else if (strcmp(a, "--video") == 0) videoMode = 1;
        else if (strcmp(a, "--audio-only") == 0) videoMode = 0;
        else if (strcmp(a, "--camera") == 0 && i + 1 < argc)
            initialCamera = strcmp(argv[++i], "front") == 0 ? QRCameraFront : QRCameraRear;
        else if (strcmp(a, "--workdir") == 0 && i + 1 < argc)
            workdir = [NSString stringWithUTF8String:argv[++i]];
        else if (strcmp(a, "--ffmpeg") == 0 && i + 1 < argc)
            ffbin = [NSString stringWithUTF8String:argv[++i]];
        else if (strcmp(a, "--logfile") == 0 && i + 1 < argc)
            logfile = [NSString stringWithUTF8String:argv[++i]];
        else if (strcmp(a, "--video-bitrate") == 0 && i + 1 < argc) vb = atoi(argv[++i]);
        else if (strcmp(a, "--audio-bitrate") == 0 && i + 1 < argc) ab = atoi(argv[++i]);
        else if (strcmp(a, "--audio-gain") == 0 && i + 1 < argc) ag = atoi(argv[++i]);
        else { usage(); return 1; }
    }

    @autoreleasepool {
        if (logfile) {
            // route all daemon logs to a file regardless of how we were
            // started (launchd, ssh nohup, SpringBoard-spawned)
            freopen([logfile fileSystemRepresentation], "a", stdout);
            freopen([logfile fileSystemRepresentation], "a", stderr);
        }
        if (initialCamera == QRCameraFront) setenv("QR_CAM", "front", 1);
        CaptureEngine *engine = [[CaptureEngine alloc] initWithFps:fps];
        FfmpegProc *proc = [[FfmpegProc alloc] init];
        proc.ffmpegPath = ffbin;
        proc.workDir = workdir;
        proc.videoBitrate = vb;
        proc.audioBitrate = ab;
        proc.audioGain = ag;
        proc.fps = fps;

        engine.delegate = proc;
        engine.fps = fps;
        engine.audioOnly = videoMode ? NO : YES;

        AudioHub *hub = [[AudioHub alloc] init];
        engine.audioHub = hub;

        HttpServer *server = [[HttpServer alloc] init];
        server.port = port;
        server.webDir = [workdir stringByAppendingPathComponent:@"web"];
        server.hlsDir = [workdir stringByAppendingPathComponent:@"hls"];
        server.engine = engine;
        server.proc = proc;
        server.audioHub = hub;
        server.audioOnly = engine.audioOnly;
        [hub release];   // owned by server (retain) from here

        NSError *err = nil;
        if (![engine start:&err]) {
            QR_LOG("capture start failed: %s\n",
                   err ? [err localizedDescription].UTF8String : "?");
            return 1;
        }
        if (videoMode && initialCamera == QRCameraFront)
            [engine switchTo:QRCameraFront error:nil];
        if (![server start:&err]) {
            QR_LOG("http server failed: %s\n",
                   err ? [err localizedDescription].UTF8String : "?");
            return 1;
        }

        QR_LOG("quietriotd up on http://0.0.0.0:%d/  (%s)\n", port,
               videoMode ? "camera+mic HLS, watch /hls/stream.m3u8"
                         : "mic-only ws PCM, open /audio");
        // AVFoundation needs the main CFRunLoop serviced (dispatch_main()
        // alone never drains it -> no sample buffers, no notifications).
        NSRunLoop *rl = [NSRunLoop mainRunLoop];
        while (1) {
            @autoreleasepool {
                [rl runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
            }
        }
    }
    return 0;
}
