#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

extern char **environ;

#define QR_PORT 8080
#define QR_DAEMON "/usr/local/bin/quietriotd"
#define QR_LOGFILE "/var/mobile/Library/quietriot/daemon.log"
#define QR_SPAWN_CMD "quietriotd --port 8080 --logfile " QR_LOGFILE " &"

@protocol BBWeeAppController <NSObject>
@required
- (UIView *)view;
@optional
- (float)viewHeight;
- (void)loadPlaceholderView;
- (void)loadFullView;
- (void)unloadView;
- (void)viewWillAppear;
- (void)viewDidDisappear;
- (void)clearShapshotImage;
@end

static void qr_alert(NSString *msg)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        UIAlertView *av = [[UIAlertView alloc]
            initWithTitle:@"QuietRiot" message:msg delegate:nil
            cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [av show];
        [av release];
        [pool drain];
    });
}

// returns malloc'd body or NULL; caller frees. timeout in ms
static char *qr_http_get(const char *path, int timeout_ms)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(QR_PORT);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NULL;
    }

    char req[256];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.0\r\nConnection: close\r\n\r\n", path);
    size_t reqlen = strlen(req);
    size_t sent = 0;
    while (sent < reqlen) {
        ssize_t n = send(fd, req + sent, reqlen - sent, 0);
        if (n <= 0) { close(fd); return NULL; }
        sent += (size_t)n;
    }

    size_t cap = 4096, used = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) { close(fd); return NULL; }
    for (;;) {
        if (used + 4096 + 1 > cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); close(fd); return NULL; }
            buf = nb;
        }
        ssize_t n = recv(fd, buf + used, 4096, 0);
        if (n <= 0) break;
        used += (size_t)n;
    }
    close(fd);
    buf[used] = 0;

    char *body = strstr(buf, "\r\n\r\n");
    if (!body) { free(buf); return NULL; }
    body += 4;
    size_t blen = buf + used - body;
    char *out = (char *)malloc(blen + 1);
    if (out) { memcpy(out, body, blen); out[blen] = 0; }
    free(buf);
    return out;
}

static void qr_spawn_daemon(void)
{
    pid_t pid = 0;
    const char *sh = "/bin/sh";
    char *argv[] = { (char *)sh, (char *)"-c",
                     "exec " QR_DAEMON " " QR_SPAWN_CMD, NULL };
    posix_spawn(&pid, sh, NULL, NULL, argv, environ);
}

@interface QuietRiotWeeAppController : NSObject <BBWeeAppController>
{
@private
    UIView *_view;
    UILabel *_status;
    UIButton *_startBtn;
    UIButton *_stopBtn;
    NSTimer *_timer;
}
- (void)refreshStatus;
- (void)startTapped;
- (void)stopTapped;
@end

@implementation QuietRiotWeeAppController

- (id)init
{
    self = [super init];
    return self;
}

- (float)viewHeight
{
    return 76.0f;
}

- (UIView *)view
{
    if (_view) return _view;

    _view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 76)];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 2, 300, 15)];
    title.text = @"QUIETRIOT";
    title.font = [UIFont boldSystemFontOfSize:11];
    title.textColor = [UIColor whiteColor];
    title.backgroundColor = [UIColor clearColor];
    title.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    title.shadowOffset = CGSizeMake(0, 1);
    [_view addSubview:title];
    [title release];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(10, 17, 300, 14)];
    _status.font = [UIFont systemFontOfSize:11];
    _status.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    _status.backgroundColor = [UIColor clearColor];
    _status.text = @"checking...";
    [_view addSubview:_status];

    _startBtn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    _startBtn.frame = CGRectMake(10, 37, 145, 33);
    [_startBtn setTitle:@"Start" forState:UIControlStateNormal];
    _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_startBtn addTarget:self action:@selector(startTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [_view addSubview:_startBtn];

    _stopBtn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    _stopBtn.frame = CGRectMake(165, 37, 145, 33);
    [_stopBtn setTitle:@"Stop" forState:UIControlStateNormal];
    _stopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_stopBtn addTarget:self action:@selector(stopTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [_view addSubview:_stopBtn];

    [self refreshStatus];
    return _view;
}

- (void)loadFullView
{
    [self view];
}

- (void)loadPlaceholderView
{
    [self view];
}

- (void)unloadView
{
    [_timer invalidate];
    [_timer release];
    _timer = nil;
    [_view release];
    _view = nil;
    _status = nil;
    _startBtn = nil;
    _stopBtn = nil;
}

- (void)viewWillAppear
{
    [self refreshStatus];
    if (!_timer) {
        _timer = [NSTimer scheduledTimerWithTimeInterval:3.0
            target:self selector:@selector(refreshStatus)
            userInfo:nil repeats:YES];
        [_timer retain];
    }
}

- (void)viewDidDisappear
{
    [_timer invalidate];
    [_timer release];
    _timer = nil;
}

- (void)clearShapshotImage
{
}

static int qr_json_int(const char *body, const char *key)
{
    if (!body) return -1;
    const char *p = strstr(body, key);
    if (!p) return -1;
    p += strlen(key);
    while (*p && *p != '-' && (*p < '0' || *p > '9')) p++;
    if (!*p) return -1;
    return atoi(p);
}

- (void)refreshStatus
{
    __block QuietRiotWeeAppController *me = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        char *body = qr_http_get("/status", 700);
        NSString *txt;
        UIColor *col;
        if (body) {
            BOOL live = strstr(body, "\"streaming\":true") != NULL;
            int ws = qr_json_int(body, "\"ws\":");
            if (live) {
                col = [UIColor colorWithRed:0.30 green:0.85 blue:0.35 alpha:1];
                if (ws > 0)
                    txt = [NSString stringWithFormat:@"● listening · %d listener%s",
                           ws, (ws == 1) ? "" : "s"];
                else
                    txt = @"● listening · no listeners yet";
            } else {
                col = [UIColor colorWithRed:0.95 green:0.70 blue:0.15 alpha:1];
                txt = @"● daemon up · paused (tap Start)";
            }
            free(body);
        } else {
            col = [UIColor colorWithRed:0.95 green:0.30 blue:0.25 alpha:1];
            txt = @"● not running (tap Start)";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (me->_status) {
                me->_status.text = txt;
                me->_status.textColor = col;
            }
        });
        [pool drain];
    });
}

- (void)startTapped
{
    char *body = qr_http_get("/status", 700);
    if (body) {
        free(body);
        char *r = qr_http_get("/start", 1500);
        BOOL live = r && strstr(r, "\"streaming\":true") != NULL;
        if (r) free(r);
        qr_alert(live ? @"QuietRiot: streaming"
                      : @"QuietRiot: daemon error (see daemon.log)");
    } else {
        qr_spawn_daemon();
        qr_alert(@"Starting QuietRiot...");
    }
    [self refreshStatus];
}

- (void)stopTapped
{
    char *body = qr_http_get("/status", 700);
    if (body) {
        free(body);
        char *r = qr_http_get("/shutdown", 1500);
        if (r) free(r);
    }
    system("/bin/killall quietriotd 2>/dev/null");
    system("/bin/killall -9 quietriot-ffmpeg 2>/dev/null");
    qr_alert(@"QuietRiot stopped");
    [self refreshStatus];
}

@end
