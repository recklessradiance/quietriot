#import "CaptureEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import "FifoWriter.h"

#define QR_LOG(...) fprintf(stderr, "[capture] " __VA_ARGS__)

@interface CaptureEngine ()
- (void)handleVideoBuffer:(CMSampleBufferRef)sb;
- (void)handleAudioBuffer:(CMSampleBufferRef)sb;
@end

@implementation CaptureEngine {
    AVCaptureSession *_session;
    AVCaptureDeviceInput *_videoInputRear;
    AVCaptureDeviceInput *_videoInputFront;
    AVCaptureDeviceInput *_audioInput;
    AVCaptureVideoDataOutput *_videoOut;
    AVCaptureAudioDataOutput *_audioOut;
    dispatch_queue_t _videoQueue;
    dispatch_queue_t _audioQueue;
    dispatch_queue_t _configQueue;

    BOOL _running;
    QRCamera _camera;
    BOOL _videoAnnounced;
    BOOL _audioAnnounced;

    // video stats
    double _lastPTS;
    double _fpsWindow[16];
    int _fpsIdx;
    double _measuredFps;
    unsigned long _videoDrops;

    // video staging (pack strided NV12 planes -> tightly packed for ffmpeg)
    uint8_t *_stage;
    size_t _stageCap;

    // audio info discovered from first buffer
    int _audioRate;
    int _audioCh;
    BOOL _audioIsFloat;
    BOOL _audioBadLogged;

    id<CaptureEngineDelegate> __unsafe_unretained _delegate;
}

@synthesize camera = _camera;
@synthesize fps = _fps;
@synthesize videoFps = _measuredFps;
@synthesize videoDrops = _videoDrops;
@synthesize running = _running;

- (id)initWithFps:(int)fps
{
    self = [super init];
    if (!self) return nil;
    _fps = fps > 0 ? fps : 15;
    _camera = QRCameraRear;
    _videoQueue = dispatch_queue_create("quietriot.video", DISPATCH_QUEUE_SERIAL);
    _audioQueue = dispatch_queue_create("quietriot.audio", DISPATCH_QUEUE_SERIAL);
    _configQueue = dispatch_queue_create("quietriot.config", DISPATCH_QUEUE_SERIAL);
    int i;
    for (i = 0; i < 16; i++) _fpsWindow[i] = 1.0 / _fps;
    return self;
}

- (void)setDelegate:(id<CaptureEngineDelegate>)d { _delegate = d; }
- (id<CaptureEngineDelegate>)delegate { return _delegate; }

- (AVCaptureDeviceInput *)makeVideoInput:(AVCaptureDevicePosition)pos error:(NSError **)err
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevice *device = nil;
    for (AVCaptureDevice *d in devices) {
        if (d.position == pos) { device = d; break; }
    }
    if (device == nil)
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (device == nil) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:1
            userInfo:[NSDictionary dictionaryWithObject:@"no camera device found"
                                                 forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    return [AVCaptureDeviceInput deviceInputWithDevice:device error:err];
}

- (BOOL)start:(NSError **)err
{
    if (_running) return YES;

    _session = [[AVCaptureSession alloc] init];
    // Medium preset = 480x360 on the 4s; the sane ceiling for A5 software x264.
    _session.sessionPreset = AVCaptureSessionPresetMedium;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(sessionRuntimeError:)
        name:AVCaptureSessionRuntimeErrorNotification object:_session];

    AVCaptureDevicePosition pos = AVCaptureDevicePositionBack;
    if (getenv("QR_CAM") && strcmp(getenv("QR_CAM"), "front") == 0)
        pos = AVCaptureDevicePositionFront;
    AVCaptureDevice *dev = nil;
    NSArray *vids = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *d in vids) {
        QR_LOG("camera candidate: %s pos=%ld connected=%d modelID=%s\n",
               d.uniqueID.UTF8String ?: "?", (long)d.position,
               d.connected ? 1 : 0, d.modelID.UTF8String ?: "?");
        if (dev == nil || d.position == pos) dev = d;
    }
    if (dev == nil) dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:err];
    if (pos == AVCaptureDevicePositionFront) _videoInputFront = in; else _videoInputRear = in;
    if (in == nil) return NO;
    _audioInput = [AVCaptureDeviceInput deviceInputWithDevice:
        [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio] error:err];

    _videoOut = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *vs = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
            (id)kCVPixelBufferPixelFormatTypeKey, nil];
    _videoOut.videoSettings = vs;
    _videoOut.minFrameDuration = CMTimeMake(1, _fps);   // iOS 6-era fps cap
    _videoOut.alwaysDiscardsLateVideoFrames = YES;
    [_videoOut setSampleBufferDelegate:self queue:_videoQueue];

    _audioOut = [[AVCaptureAudioDataOutput alloc] init];
    [_audioOut setSampleBufferDelegate:self queue:_audioQueue];

    [_session beginConfiguration];
    [_session addInput:_videoInputRear];
    if (!getenv("QR_NO_AUDIO")) {
        if (_audioInput) [_session addInput:_audioInput];
        [_session addOutput:_audioOut];
    }
    [_session addOutput:_videoOut];
    [_session commitConfiguration];
    QR_LOG("session wiring done: videoConns=%lu audioConns=%lu\n",
           (unsigned long)[_videoOut.connections count],
           (unsigned long)[_audioOut.connections count]);
    _camera = QRCameraRear;

    [self applyOrientation];

    AVAudioSession *as = [AVAudioSession sharedInstance];
    [as setCategory:AVAudioSessionCategoryRecord error:nil];
    if (!getenv("QR_NO_AUDIO")) [as setActive:YES error:nil];

    _running = YES;
    AVCaptureSession *s = _session;
    dispatch_async(_configQueue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [s startRunning];
        QR_LOG("startRunning done: running=%d hasVideoConn=%d\n",
               s.running ? 1 : 0, [self videoConnection] != nil ? 1 : 0);
        [pool drain];
    });
    return YES;
}

- (AVCaptureConnection *)videoConnection
{
    for (AVCaptureConnection *c in _videoOut.connections) {
        if ([c.inputPorts count] > 0) return c;
    }
    return nil;
}

- (void)applyOrientation
{
    AVCaptureConnection *conn = [self videoConnection];
    if (conn == nil) {
        QR_LOG("orientation: no video connection yet\n");
        return;
    }
    if (!getenv("QR_NO_ORIENT")) {
        if (conn.supportsVideoOrientation) {
            conn.videoOrientation = AVCaptureVideoOrientationPortrait;
            QR_LOG("orientation set portrait (supports=%d)\n",
                   conn.supportsVideoOrientation ? 1 : 0);
        }
    } else {
        QR_LOG("orientation SKIPPED (QR_NO_ORIENT)\n");
    }
    // iOS 6: fps cap lives on the connection, not the data output
    if (!getenv("QR_NO_FPS")) {
        if (conn.supportsVideoMinFrameDuration)
            conn.videoMinFrameDuration = CMTimeMake(1, _fps);
    }
    QR_LOG("conn state: enabled=%d orientation=%ld minFps=%d/%d supported minFps=%d\n",
           conn.enabled ? 1 : 0, (long)conn.videoOrientation,
           (int)CMTimeGetSeconds(conn.videoMinFrameDuration),
           _fps, conn.supportsVideoMinFrameDuration ? 1 : 0);
}

- (void)stop
{
    if (!_running) return;
    _running = NO;
    AVCaptureSession *s = _session;
    dispatch_async(_configQueue, ^{
        [s stopRunning];
    });
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
}

- (BOOL)switchTo:(QRCamera)camera error:(NSError **)err
{
    if (!_running) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:2
            userInfo:[NSDictionary dictionaryWithObject:@"not running"
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    AVCaptureDeviceInput *target = (camera == QRCameraFront) ? _videoInputFront : _videoInputRear;
    AVCaptureDeviceInput *other  = (camera == QRCameraFront) ? _videoInputRear  : _videoInputFront;

    if (target == nil) {
        NSError *e2 = nil;
        target = [self makeVideoInput:
            (camera == QRCameraFront) ? AVCaptureDevicePositionFront
                                      : AVCaptureDevicePositionBack error:&e2];
        if (target == nil) { if (err) *err = e2; return NO; }
        if (camera == QRCameraFront) _videoInputFront = target;
        else _videoInputRear = target;
    }
    if (target == other) return YES;

    __block BOOL ok = NO;
    __block NSError *swErr = nil;
    dispatch_sync(_configQueue, ^{
        [self->_session beginConfiguration];
        [self->_session removeInput:other];
        if ([self->_session canAddInput:target])
            [self->_session addInput:target];
        else
            swErr = [NSError errorWithDomain:@"quietriot" code:3
                userInfo:[NSDictionary dictionaryWithObject:@"cannot add camera input"
                                                     forKey:NSLocalizedDescriptionKey]];
        [self->_session commitConfiguration];
        if (swErr == nil) {
            self->_camera = camera;
            [self applyOrientation];
            ok = YES;
            QR_LOG("switched to %s camera\n", camera == QRCameraFront ? "FRONT" : "REAR");
            id<CaptureEngineDelegate> d = self->_delegate;
            if (d && [d respondsToSelector:@selector(captureSwitchedTo:)])
                [d captureSwitchedTo:camera];
        }
    });
    if (err) *err = swErr;
    return ok;
}

- (void)dealloc
{
    if (_stage) free(_stage);
    [super dealloc];
}

#pragma mark - buffer handlers

- (void)handleVideoBuffer:(CMSampleBufferRef)sb
{
    if (!_running) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb == nil) return;

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);

    if (!_videoAnnounced) {
        _videoAnnounced = YES;
        QR_LOG("first video frame: %dx%d\n", (int)w, (int)h);
        id<CaptureEngineDelegate> d = _delegate;
        if (d && [d respondsToSelector:@selector(captureVideoReady:height:fps:)])
            [d captureVideoReady:(int)w height:(int)h fps:_fps];
    }

    uint8_t *y  = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (y != nil && uv != nil) {
        size_t yStride  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        size_t frameSize = w * h * 3 / 2;
        if (_stageCap < frameSize) {
            if (_stage) free(_stage);
            _stage = (uint8_t *)malloc(frameSize);
            _stageCap = _stage ? frameSize : 0;
        }
        if (_stage) {
            size_t r;
            for (r = 0; r < h; r++)
                memcpy(_stage + r * w, y + r * yStride, w);
            uint8_t *uvOut = _stage + w * h;
            for (r = 0; r < h / 2; r++)
                memcpy(uvOut + r * w, uv + r * uvStride, w);
            [self writeVideo:_stage length:frameSize];
        }
    }

    // fps measurement (rolling 16-frame window)
    double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
    if (_lastPTS > 0) {
        double d = pts - _lastPTS;
        if (d > 0.001 && d < 2.0) {
            _fpsWindow[_fpsIdx & 15] = d;
            _fpsIdx++;
            double sum = 0;
            int i;
            for (i = 0; i < 16; i++) sum += _fpsWindow[i];
            _measuredFps = sum > 0 ? 16.0 / sum : 0;
        }
    }
    _lastPTS = pts;

    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

- (void)handleAudioBuffer:(CMSampleBufferRef)sb
{
    if (!_running) return;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (fmt == nil) return;

    if (!_audioAnnounced) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (asbd != nil) {
            _audioRate = (int)asbd->mSampleRate;
            _audioCh   = (int)asbd->mChannelsPerFrame;
            _audioIsFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
            BOOL signedInt = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
            BOOL packed    = (asbd->mFormatFlags & kAudioFormatFlagIsPacked) != 0;
            _audioAnnounced = YES;
            QR_LOG("audio: rate=%d ch=%d bits=%u %s/%s/%s\n", _audioRate, _audioCh,
                   (unsigned)asbd->mBitsPerChannel,
                   _audioIsFloat ? "float" : "int",
                   signedInt ? "signed" : "unsigned",
                   packed ? "packed" : "unpacked");
            if (!_audioIsFloat && !(signedInt && asbd->mBitsPerChannel == 16 && packed)) {
                _audioBadLogged = YES;
                QR_LOG("WARNING: unsupported audio format; audio will be missing\n");
            }
            id<CaptureEngineDelegate> d = _delegate;
            if (d && [d respondsToSelector:@selector(captureAudioReady:channels:isFloat:)])
                [d captureAudioReady:_audioRate channels:_audioCh isFloat:_audioIsFloat];
        }
    }
    if (_audioBadLogged) return;

    AudioBufferList list;
    UInt32 listSize = sizeof(list);
    CMBlockBufferRef block = NULL;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sb, &listSize, &list, sizeof(list), NULL, NULL, 0, &block);
    if (st != noErr || block == NULL) return;

    // iOS delivers one interleaved buffer; if planar, we only take buffer 0
    if (list.mNumberBuffers >= 1 && list.mBuffers[0].mData != nil) {
        unsigned long len = list.mBuffers[0].mDataByteSize;
        if (_audioIsFloat) {
            const float *src = (const float *)list.mBuffers[0].mData;
            unsigned long n = len / sizeof(float);
            if (_stageCap < n * 2) {
                if (_stage) free(_stage);
                _stage = (uint8_t *)malloc(n * 2);
                _stageCap = _stage ? n * 2 : 0;
            }
            if (_stage) {
                int16_t *dst = (int16_t *)_stage;
                unsigned long i;
                for (i = 0; i < n; i++) {
                    float s = src[i];
                    if (s > 1.0f) s = 1.0f;
                    if (s < -1.0f) s = -1.0f;
                    dst[i] = (int16_t)(s * 32767.0f);
                }
                [self writeAudio:_stage length:n * 2];
            }
        } else {
            [self writeAudio:list.mBuffers[0].mData length:len];
        }
    }
    if (block) CFRelease(block);
}

- (void)writeVideo:(const void *)buf length:(unsigned long)len
{
    id<CaptureEngineDelegate> d = _delegate;
    if (d && [d respondsToSelector:@selector(writeVideoStream:length:)]) {
        long n = [d writeVideoStream:buf length:len];
        if (n < 0) _videoDrops++;
    } else {
        _videoDrops++;
    }
}

- (void)writeAudio:(const void *)buf length:(unsigned long)len
{
    id<CaptureEngineDelegate> d = _delegate;
    if (d && [d respondsToSelector:@selector(writeAudioStream:length:)])
        [d writeAudioStream:buf length:len];
}

- (void)sessionRuntimeError:(NSNotification *)n
{
    NSError *e = [n.userInfo objectForKey:AVCaptureSessionErrorKey];
    QR_LOG("SESSION RUNTIME ERROR: %s\n", e.description.UTF8String ?: "?");
}

#pragma mark - AVCapture sample buffer delegates

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (output == _videoOut)
        [self handleVideoBuffer:sampleBuffer];
    else
        [self handleAudioBuffer:sampleBuffer];
    [pool drain];
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    _videoDrops++;
}

@end
