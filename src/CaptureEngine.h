#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef enum {
    QRCameraRear = 0,
    QRCameraFront = 1
} QRCamera;

@class AudioHub;

@protocol CaptureEngineDelegate <NSObject>
@optional
- (void)captureVideoReady:(int)width height:(int)height fps:(int)fps;
- (void)captureAudioReady:(int)sampleRate channels:(int)channels isFloat:(BOOL)isFloat;
- (void)captureSwitchedTo:(QRCamera)camera;
// stream sinks; video returns -1 when the frame was dropped
- (long)writeVideoStream:(const void *)buf length:(unsigned long)len;
- (void)writeAudioStream:(const void *)buf length:(unsigned long)len;
@end

@interface CaptureEngine : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate,
                                     AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, assign, readonly) QRCamera camera;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) id<CaptureEngineDelegate> delegate;
@property (nonatomic, assign) BOOL audioOnly;      // mic-only: no camera, no ffmpeg
@property (nonatomic, assign) AudioHub *audioHub;  // ws pcm tap (not retained)

@property (nonatomic, assign, readonly) double videoFps;
@property (nonatomic, assign, readonly) unsigned long videoDrops;
@property (nonatomic, assign, readonly) BOOL running;

- (id)initWithFps:(int)fps;
- (BOOL)start:(NSError **)err;
- (void)stop;
- (BOOL)switchTo:(QRCamera)camera error:(NSError **)err;

@end
