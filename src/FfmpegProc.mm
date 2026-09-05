#import "FfmpegProc.h"
#import "FifoWriter.h"
#import "CaptureEngine.h"

#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

extern char **environ;

#define QR_LOG(...) fprintf(stderr, "[ffmpeg] " __VA_ARGS__)

@implementation FfmpegProc {
    QRFifo _vFifo;
    QRFifo _aFifo;
    pid_t _pid;
    dispatch_source_t _monitor;
    dispatch_queue_t _queue;
    int _restarts;

    // last known stream params (for respawn)
    int _w, _h, _fps, _rate, _ch;
    BOOL _startedOnce;

    // pending params announced by the capture engine (start when both known)
    int _pendW, _pendH, _pendRate, _pendCh;
}

@synthesize ffmpegPath = _ffmpegPath;
@synthesize workDir = _workDir;
@synthesize videoBitrate = _videoBitrate;
@synthesize audioBitrate = _audioBitrate;
@synthesize fps = _fps;

- (id)init
{
    self = [super init];
    if (!self) return nil;
    _pid = -1;
    _vFifo.fd = -1;
    _aFifo.fd = -1;
    _queue = dispatch_queue_create("quietriot.ffmpeg", DISPATCH_QUEUE_SERIAL);
    _ffmpegPath = @"/usr/local/bin/quietriot-ffmpeg";
    _workDir = @"/var/mobile/Library/quietriot";
    _videoBitrate = 400;
    _audioBitrate = 64;
    _fps = 15;
    return self;
}

- (pid_t)pid { return _pid; }
- (BOOL)alive { return _pid > 0; }

- (BOOL)prepareDirs:(NSError **)err
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL ok = [fm createDirectoryAtPath:_workDir withIntermediateDirectories:YES
                             attributes:nil error:err];
    ok = ok && [fm createDirectoryAtPath:[_workDir stringByAppendingPathComponent:@"hls"]
             withIntermediateDirectories:YES attributes:nil error:err];
    // the daemon may be (re)spawned by the Activator tweak from SpringBoard
    // (mobile user); make the work dirs writable for it
    chmod([_workDir fileSystemRepresentation], 0777);
    chmod([[_workDir stringByAppendingPathComponent:@"hls"] fileSystemRepresentation], 0777);
    return ok;
}

- (void)ensureMonitor
{
    if (_monitor != nil) return;
    _monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_monitor, DISPATCH_TIME_NOW,
                              2.0 * NSEC_PER_SEC, 1.0 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(_monitor, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [self checkProcess];
        [pool drain];
    });
    dispatch_resume(_monitor);
}

- (BOOL)spawnWithParams:(NSError **)err
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (![_workDir length]) { [pool drain]; return NO; }
    if (![self prepareDirs:err]) { [pool drain]; return NO; }

    char ffPath[PATH_MAX], fifoVPath[PATH_MAX], fifoAPath[PATH_MAX];
    char segPath[PATH_MAX], plPath[PATH_MAX], lgPath[PATH_MAX];
    snprintf(ffPath, sizeof(ffPath), "%s", [_ffmpegPath fileSystemRepresentation]);
    snprintf(fifoVPath, sizeof(fifoVPath), "%s",
             [[_workDir stringByAppendingPathComponent:@"video.fifo"] fileSystemRepresentation]);
    snprintf(fifoAPath, sizeof(fifoAPath), "%s",
             [[_workDir stringByAppendingPathComponent:@"audio.fifo"] fileSystemRepresentation]);
    snprintf(segPath, sizeof(segPath), "%s",
             [[_workDir stringByAppendingPathComponent:@"hls/seg%05d.ts"] fileSystemRepresentation]);
    snprintf(plPath, sizeof(plPath), "%s",
             [[_workDir stringByAppendingPathComponent:@"hls/stream.m3u8"] fileSystemRepresentation]);
    snprintf(lgPath, sizeof(lgPath), "%s",
             [[_workDir stringByAppendingPathComponent:@"ffmpeg.log"] fileSystemRepresentation]);

    const char *ff = ffPath;
    const char *fifoV = fifoVPath;
    const char *fifoA = fifoAPath;

    if (_vFifo.fd < 0 && !qr_fifo_open(&_vFifo, fifoV)) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:4
            userInfo:[NSDictionary dictionaryWithObject:@"cannot create video fifo"
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    if (_aFifo.fd < 0 && !qr_fifo_open(&_aFifo, fifoA)) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:4
            userInfo:[NSDictionary dictionaryWithObject:@"cannot create audio fifo"
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }

    char vsize[32], fpsArg[16], rateArg[16], chArg[8], vb[32], mr[32], bs[32], ab[32];
    snprintf(vsize, sizeof(vsize), "%dx%d", _w, _h);
    snprintf(fpsArg, sizeof(fpsArg), "%d", _fps);
    snprintf(rateArg, sizeof(rateArg), "%d", _rate);
    snprintf(chArg, sizeof(chArg), "%d", _ch);
    snprintf(vb, sizeof(vb), "%dk", _videoBitrate);
    snprintf(mr, sizeof(mr), "%dk", _videoBitrate * 12 / 10);
    snprintf(bs, sizeof(bs), "%dk", _videoBitrate * 2);
    snprintf(ab, sizeof(ab), "%dk", _audioBitrate);

    const char *argv[96];
    int i = 0;
    argv[i++] = ff;
    argv[i++] = "-y";
    argv[i++] = "-nostdin";
    argv[i++] = "-loglevel"; argv[i++] = "warning";
    argv[i++] = "-f"; argv[i++] = "rawvideo";
    argv[i++] = "-pix_fmt"; argv[i++] = "nv12";
    argv[i++] = "-video_size"; argv[i++] = vsize;
    argv[i++] = "-framerate"; argv[i++] = fpsArg;
    argv[i++] = "-i"; argv[i++] = fifoV;
    argv[i++] = "-f"; argv[i++] = "s16le";
    argv[i++] = "-ar"; argv[i++] = rateArg;
    argv[i++] = "-ac"; argv[i++] = chArg;
    argv[i++] = "-i"; argv[i++] = fifoA;
    argv[i++] = "-c:v"; argv[i++] = "libx264";
    argv[i++] = "-preset"; argv[i++] = "ultrafast";
    argv[i++] = "-tune"; argv[i++] = "zerolatency";
    argv[i++] = "-profile:v"; argv[i++] = "baseline";
    argv[i++] = "-level"; argv[i++] = "3.0";
    argv[i++] = "-pix_fmt"; argv[i++] = "yuv420p";
    argv[i++] = "-b:v"; argv[i++] = vb;
    argv[i++] = "-maxrate"; argv[i++] = mr;
    argv[i++] = "-bufsize"; argv[i++] = bs;
    argv[i++] = "-g"; argv[i++] = "30";
    argv[i++] = "-keyint_min"; argv[i++] = "15";
    argv[i++] = "-sc_threshold"; argv[i++] = "0";
    argv[i++] = "-threads"; argv[i++] = "2";
    argv[i++] = "-r"; argv[i++] = fpsArg;
    argv[i++] = "-c:a"; argv[i++] = "aac";
    argv[i++] = "-b:a"; argv[i++] = ab;
    argv[i++] = "-f"; argv[i++] = "hls";
    argv[i++] = "-hls_time"; argv[i++] = "1";
    argv[i++] = "-hls_list_size"; argv[i++] = "3";
    argv[i++] = "-hls_flags"; argv[i++] = "delete_segments";
    argv[i++] = "-hls_segment_filename"; argv[i++] = segPath;
    argv[i++] = plPath;
    argv[i++] = NULL;

    if (access(ff, X_OK) != 0) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:5
            userInfo:[NSDictionary dictionaryWithObject:
                      [NSString stringWithFormat:@"ffmpeg binary missing/not executable: %@", _ffmpegPath]
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    int logfd = open(lgPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (logfd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, logfd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, logfd, STDERR_FILENO);
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    pid_t pid = -1;
    int rc = posix_spawn(&pid, ff, &fa, &attr, (char *const *)argv, environ);
    if (logfd >= 0) close(logfd);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:6
            userInfo:[NSDictionary dictionaryWithObject:
                      [NSString stringWithFormat:@"posix_spawn failed: %s", strerror(rc)]
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    _pid = pid;
    _startedOnce = YES;
    [self ensureMonitor];
    QR_LOG("spawned pid %d (%dx%d@%d, %dHz/%dch, %dkbps v / %dkbps a)\n",
           (int)_pid, _w, _h, _fps, _rate, _ch, _videoBitrate, _audioBitrate);
    [pool drain];
    return YES;
}

- (BOOL)startWithVideoWidth:(int)w height:(int)h
                  audioRate:(int)rate channels:(int)ch isFloat:(BOOL)isFloat
                      error:(NSError **)err
{
    _w = w; _h = h; _rate = rate; _ch = ch; _fps = _fps > 0 ? _fps : 15;
    BOOL ok = [self spawnWithParams:err];
    if (ok) [self ensureMonitor];
    return ok;
}

- (void)checkProcess
{
    if (_pid <= 0) return;
    int st = 0;
    pid_t r = waitpid(_pid, &st, WNOHANG);
    if (r == _pid) {
        QR_LOG("ffmpeg pid %d exited (status %d), restarts=%d\n", (int)_pid, st, _restarts);
        _pid = -1;
        if (++_restarts > 10) {
            QR_LOG("too many ffmpeg restarts, giving up\n");
            return;
        }
        int backoff = _restarts * 2;
        if (backoff > 20) backoff = 20;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, backoff * NSEC_PER_SEC),
                       _queue, ^{
            NSError *e = nil;
            if (![self spawnWithParams:&e]) {
                QR_LOG("respawn failed: %s\n", e ? e.localizedDescription.UTF8String : "?");
            }
        });
    }
}

- (long)writeVideoStream:(const void *)buf length:(unsigned long)len
{
    return qr_fifo_write(&_vFifo, buf, len);
}

#pragma mark - CaptureEngineDelegate (first-buffer handoff)

- (void)captureVideoReady:(int)width height:(int)height fps:(int)fps
{
    _pendW = width; _pendH = height;
    _fps = fps > 0 ? fps : _fps;
    [self tryStart];
}

- (void)captureAudioReady:(int)sampleRate channels:(int)channels isFloat:(BOOL)isFloat
{
    _pendRate = sampleRate; _pendCh = channels;
    [self tryStart];
}

- (void)tryStart
{
    if (_pendW > 0 && _pendRate > 0 && _pid <= 0 && !_startedOnce) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSError *e = nil;
        _w = _pendW; _h = _pendH; _rate = _pendRate; _ch = _pendCh;
        if (![self spawnWithParams:&e])
            QR_LOG("failed to start ffmpeg: %s\n", e ? e.localizedDescription.UTF8String : "?");
        [pool drain];
    }
}

- (void)captureSwitchedTo:(QRCamera)camera
{
    // stream continues across camera switches; nothing to do for ffmpeg
}

- (void)writeAudioStream:(const void *)buf length:(unsigned long)len
{
    qr_fifo_write(&_aFifo, buf, len);
}

- (void)stop
{
    // NOTE: the monitor source stays alive (a no-op while _pid <= 0) so a
    // later restart stays supervised; only dealloc cancels it.
    if (_pid > 0) {
        kill(_pid, SIGTERM);
        int st;
        // give it 2 seconds to exit cleanly
        for (int i = 0; i < 20 && waitpid(_pid, &st, WNOHANG) == 0; i++) {
            usleep(100000);
        }
        if (kill(_pid, 0) == 0) kill(_pid, SIGKILL);
        waitpid(_pid, &st, 0);
        _pid = -1;
    }
    qr_fifo_close(&_vFifo);
    qr_fifo_close(&_aFifo);
    unlink([[_workDir stringByAppendingPathComponent:@"video.fifo"] fileSystemRepresentation]);
    unlink([[_workDir stringByAppendingPathComponent:@"audio.fifo"] fileSystemRepresentation]);
    // make the next start() spawn ffmpeg from scratch
    _startedOnce = NO;
    _restarts = 0;
    _pendW = _pendH = _pendRate = _pendCh = 0;
    _w = _h = _rate = _ch = 0;
}

- (void)dealloc
{
    [self stop];
    if (_monitor) {
        dispatch_source_cancel(_monitor);
        _monitor = nil;
    }
    [_ffmpegPath release];
    [_workDir release];
    [super dealloc];
}

@end
