#import <Foundation/Foundation.h>

@class CaptureEngine;
@class FfmpegProc;

// Minimal threaded HTTP/1.1 server: control page, HLS files, camera switch,
// status JSON. Range requests supported (needed for Safari video tags).

@interface HttpServer : NSObject

@property (nonatomic, assign) int port;             // default 8080
@property (nonatomic, copy) NSString *webDir;       // index.html, hls.min.js
@property (nonatomic, copy) NSString *hlsDir;       // .m3u8 / .ts files
@property (nonatomic, retain) CaptureEngine *engine;
@property (nonatomic, retain) FfmpegProc *proc;

- (BOOL)start:(NSError **)err;
- (void)stop;

@end
