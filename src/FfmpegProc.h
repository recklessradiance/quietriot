#import <Foundation/Foundation.h>
#import "CaptureEngine.h"

@class CaptureEngine;

// Owns the on-device ffmpeg process: named pipes for raw video/pcm in,
// HLS playlist + segments out. Restarts ffmpeg if it dies.

@interface FfmpegProc : NSObject <CaptureEngineDelegate>

@property (nonatomic, readonly) pid_t pid;
@property (nonatomic, assign, readonly) BOOL alive;

@property (nonatomic, copy) NSString *ffmpegPath;   // default /usr/local/bin/quietriot-ffmpeg
@property (nonatomic, copy) NSString *workDir;      // default /var/mobile/Library/quietriot
@property (nonatomic, assign) int videoBitrate;     // kbit/s, default 400
@property (nonatomic, assign) int audioBitrate;     // kbit/s, default 64
@property (nonatomic, assign) int fps;              // default 15

- (BOOL)startWithVideoWidth:(int)w height:(int)h
                  audioRate:(int)rate channels:(int)ch isFloat:(BOOL)isFloat
                      error:(NSError **)err;

- (void)stop;

@end
