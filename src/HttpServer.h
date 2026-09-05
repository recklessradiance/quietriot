#import <Foundation/Foundation.h>

@class CaptureEngine;
@class FfmpegProc;
@class AudioHub;

// Minimal threaded HTTP/1.1 server: control page, HLS files, camera switch,
// status JSON. Range requests supported (needed for Safari video tags).
// Also upgrades GET /ws/audio to a WebSocket and fans raw PCM out via
// an AudioHub.

@interface HttpServer : NSObject

@property (nonatomic, assign) int port;             // default 8080
@property (nonatomic, copy) NSString *webDir;       // index.html, audio.html, hls.min.js
@property (nonatomic, copy) NSString *hlsDir;       // .m3u8 / .ts files
@property (nonatomic, retain) CaptureEngine *engine;
@property (nonatomic, retain) FfmpegProc *proc;
@property (nonatomic, retain) AudioHub *audioHub;
@property (nonatomic, assign) BOOL audioOnly;       // default mode: mic-only, no camera/ffmpeg

- (BOOL)start:(NSError **)err;
- (void)stop;

@end
