// quietriotctl - Activator listener tweak (loaded into SpringBoard by
// MobileSubstrate). Lets the user start/stop the quietriotd stream with any
// gesture assigned in Activator.
//
// The tweak is privilege-free: it talks to quietriotd over localhost HTTP
// (mobile user -> root daemon works fine). If the daemon is not running it
// spawns a fresh instance (as mobile - all its state lives under
// /var/mobile/Library/quietriot, no TCC prompts exist on iOS 6 for camera).
//
// No Activator headers are used: LAActivator is resolved at runtime via
// NSClassFromString, so this dylib loads harmlessly when Activator is absent.

#import <Foundation/Foundation.h>
#import <UIKit/UIAlertView.h>
#import <objc/message.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <spawn.h>

extern char **environ;

#define QR_PORT        8080
#define QR_DAEMON      "/usr/local/bin/quietriotd"
#define QR_LOGFILE     "/var/mobile/Library/quietriot/daemon.log"

enum { QR_MODE_TOGGLE = 0, QR_MODE_START = 1, QR_MODE_STOP = 2 };

static void qr_alert(NSString *msg)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"QuietRiot"
                                                    message:msg
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
        [a show];
        [a release];
    });
}

// GET http://127.0.0.1:8080<path>; returns malloc'd body or NULL
static char *qr_http_get(const char *path)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    struct timeval tv = { 3, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(QR_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        close(fd);
        return NULL;
    }
    char req[256];
    snprintf(req, sizeof req,
             "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
             path);
    if (write(fd, req, strlen(req)) < 0) { close(fd); return NULL; }

    size_t cap = 4096, len = 0;
    char *buf = (char *)malloc(cap);
    for (;;) {
        if (len + 1024 > cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); close(fd); return NULL; }
            buf = nb;
        }
        ssize_t n = read(fd, buf + len, cap - len - 1);
        if (n <= 0) break;
        len += (size_t)n;
    }
    close(fd);
    buf[len] = 0;

    char *body = strstr(buf, "\r\n\r\n");
    if (!body) { free(buf); return NULL; }
    body += 4;
    char *out = strdup(body);
    free(buf);
    return out;
}

// spawn quietriotd detached from SpringBoard (sh -c ... & reparents to
// launchd). Runs as mobile; logs via the daemon's own --logfile option.
static void qr_spawn_daemon(void)
{
    char cmd[512];
    snprintf(cmd, sizeof cmd,
             "%s --port %d --logfile %s &", QR_DAEMON, QR_PORT, QR_LOGFILE);
    char *argv[] = { "/bin/sh", "-c", cmd, NULL };
    pid_t pid = -1;
    posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
}

#define QR_WORKDIR "/var/mobile/Library/quietriot"

static BOOL qr_daemon_running(void)
{
    char *body = qr_http_get("/status");
    if (body) {
        free(body);
        return YES;
    }
    return NO;
}

// gestures control the daemon PROCESS, not just the stream: kill the daemon
// (its TERM handler kills the encoder too), then sweep for strays + fifos.
static void qr_stop_process(void)
{
    system("/bin/killall quietriotd 2>/dev/null");
    system("/bin/killall quietriot-ffmpeg 2>/dev/null");
    system("/bin/rm -f " QR_WORKDIR "/video.fifo " QR_WORKDIR "/audio.fifo");
}

static void qr_start_or_alert(BOOL running)
{
    if (running) {
        qr_alert(@"QuietRiot already running");
        return;
    }
    qr_spawn_daemon();   // daemon starts streaming immediately (default camera)
    qr_alert(@"Starting QuietRiot...");
}

static void qr_toggle(int mode)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    BOOL running = qr_daemon_running();

    if (mode == QR_MODE_START) {
        qr_start_or_alert(running);
    } else if (mode == QR_MODE_STOP) {
        if (running) {
            qr_stop_process();
            qr_alert(@"QuietRiot stopped");
        } else {
            qr_alert(@"QuietRiot not running");
        }
    } else {
        if (running) {
            qr_stop_process();
            qr_alert(@"QuietRiot stopped");
        } else {
            qr_start_or_alert(NO);
        }
    }
    [pool drain];
}

@interface QRListener : NSObject
{
    int _mode;
}
- (id)initWithMode:(int)mode;
@end

@implementation QRListener
- (id)initWithMode:(int)mode
{
    self = [super init];
    if (!self) return nil;
    _mode = mode;
    return self;
}

- (void)activator:(id)activator receiveEvent:(id)event
{
    // multi-phase gestures deliver begin/end events; act only once
    if ([event respondsToSelector:@selector(type)]) {
        // objc_msgSend (not [event type]) - `id` makes clang see many `type`
        // prototypes (UIEvent etc.) and warn about ambiguity
        NSString *t = ((NSString *(*)(id, SEL))objc_msgSend)(event, @selector(type));
        if ([t isEqualToString:@"se-begin"] || [t isEqualToString:@"se-end"])
            return;
    }
    qr_toggle(_mode);
}

- (void)activator:(id)activator receiveActionsForListenerName:(NSString *)name
{
    qr_toggle(_mode);
}

+ (NSString *)activator:(id)activator requiresLocalizedTitleForListenerName:(NSString *)name
{
    if ([name isEqualToString:@"com.quietriot.toggle"]) return @"QuietRiot: Toggle stream";
    if ([name isEqualToString:@"com.quietriot.start"])  return @"QuietRiot: Start stream";
    if ([name isEqualToString:@"com.quietriot.stop"])   return @"QuietRiot: Stop stream";
    return name;
}

+ (NSString *)activator:(id)activator requiresLocalizedDescriptionForListenerName:(NSString *)name
{
    return @"Start/stop the quietriot daemon process (camera + mic HLS stream)";
}

+ (NSString *)activator:(id)activator requiresLocalizedGroupNameForListenerName:(NSString *)name
{
    return @"QuietRiot";
}

@end

static QRListener *qr_listeners[3];
static const char *qr_names[3] = {
    "com.quietriot.toggle",
    "com.quietriot.start",
    "com.quietriot.stop"
};

static void qr_register(void)
{
    Class cls = NSClassFromString(@"LAActivator");
    if (!cls) return;                       // Activator not installed
    id shared = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(sharedInstance));
    if (!shared) return;
    SEL reg = @selector(registerListener:forName:);
    if (![shared respondsToSelector:reg]) return;

    void (*regFn)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
    int i;
    for (i = 0; i < 3; i++) {
        qr_listeners[i] = [[QRListener alloc] initWithMode:i];
        regFn(shared, reg, qr_listeners[i], (id)[NSString stringWithUTF8String:qr_names[i]]);
    }
}

__attribute__((constructor))
static void quietriotctl_ctor(void)
{
    // Substrate loads dylibs alphabetically, so Activator.dylib (A) is up
    // before we are (q). Register immediately; if sharedInstance ever fails,
    // a respring fixes the ordering.
    qr_register();
}
