#import "HttpServer.h"
#import "CaptureEngine.h"
#import "FfmpegProc.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>
#include <strings.h>
#include <stdint.h>

HttpServer *qr_shared_server = NULL;

#define QR_LOG(...) fprintf(stderr, "[http] " __VA_ARGS__)

static void *qr_accept_thread(void *ctx);
static void *qr_conn_thread(void *arg);

static const char *qr_mime_m3u8 = "application/vnd.apple.mpegurl";
static const char *qr_mime_ts   = "video/mp2t";

@implementation HttpServer {
    int _listenFd;
    volatile BOOL _stopping;
    time_t _startedAt;
}

@synthesize port = _port;
@synthesize webDir = _webDir;
@synthesize hlsDir = _hlsDir;
@synthesize engine = _engine;
@synthesize proc = _proc;

- (id)init
{
    self = [super init];
    if (!self) return nil;
    _listenFd = -1;
    _port = 8080;
    _startedAt = time(NULL);
    return self;
}

- (BOOL)start:(NSError **)err
{
    _listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:10
            userInfo:[NSDictionary dictionaryWithObject:@"socket() failed"
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    int one = 1;
    setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(_port);
    if (bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        if (err) *err = [NSError errorWithDomain:@"quietriot" code:11
            userInfo:[NSDictionary dictionaryWithObject:
                      [NSString stringWithFormat:@"bind port %d failed: %s", _port, strerror(errno)]
                                                 forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    listen(_listenFd, 16);
    qr_shared_server = self;
    _stopping = NO;
    pthread_t t;
    pthread_create(&t, NULL, qr_accept_thread, (void *)self);
    pthread_detach(t);
    return YES;
}

- (void)stop
{
    _stopping = YES;
    if (_listenFd >= 0) {
        close(_listenFd);
        _listenFd = -1;
    }
}

- (void)dealloc
{
    [self stop];
    [_webDir release];
    [_hlsDir release];
    [_engine release];
    [_proc release];
    [super dealloc];
}

#pragma mark - request handling (static helpers)

static void qr_send_all(int fd, const char *buf, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = send(fd, buf + done, len - done, 0);
        if (n <= 0) return;
        done += (size_t)n;
    }
}

static void qr_send_status(int fd, int code, const char *reason,
                           const char *ctype, const char *cache,
                           const char *extra, long long clen)
{
    char h[1024];
    int n = snprintf(h, sizeof(h),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %lld\r\n"
        "Accept-Ranges: bytes\r\n"
        "Server: quietriot\r\n"
        "Connection: close\r\n",
        code, reason, ctype ? ctype : "application/octet-stream",
        clen);
    (void)n;
    if (cache) n += snprintf(h + n, sizeof(h) - n, "Cache-Control: %s\r\n", cache);
    if (extra) n += snprintf(h + n, sizeof(h) - n, "%s", extra);
    n += snprintf(h + n, sizeof(h) - n, "\r\n");
    qr_send_all(fd, h, (size_t)n);
}

// stream a file (optionally a byte range) to fd
static void qr_pump_file(int fd, FILE *fp, long long start, long long end)
{
    static char buf[16384];
    if (fseeko(fp, (off_t)start, SEEK_SET) != 0) return;
    long long pos = start;
    while (pos <= end) {
        size_t want = sizeof(buf);
        if ((long long)want > end - pos + 1) want = (size_t)(end - pos + 1);
        size_t got = fread(buf, 1, want, fp);
        if (got == 0) break;
        size_t done = 0;
        while (done < got) {
            ssize_t n = send(fd, buf + done, got - done, 0);
            if (n <= 0) return;
            done += (size_t)n;
        }
        pos += (long long)got;
        if (got < want) break;
    }
}

static void qr_serve_file(int fd, NSString *path, const char *ctype,
                          const char *cache, const char *range)
{
    FILE *fp = fopen([path fileSystemRepresentation], "rb");
    if (!fp) {
        qr_send_status(fd, 404, "Not Found", "text/plain", "no-cache", NULL, 9);
        qr_send_all(fd, "not found", 9);
        return;
    }
    fseeko(fp, 0, SEEK_END);
    long long size = ftello(fp);
    rewind(fp);

    long long start = 0, end = size - 1;
    int isRange = 0;
    if (range && strncmp(range, "bytes=", 6) == 0) {
        long long a = 0, b = -1;
        if (sscanf(range + 6, "%lld-%lld", &a, &b) >= 1) {
            if (a < 0) a = 0;
            if (b < 0 || b >= size) b = size - 1;
            if (a <= b) {
                start = a;
                end = b;
                isRange = 1;
            }
        }
    }
    if (isRange) {
        char extra[160];
        snprintf(extra, sizeof(extra), "Content-Range: bytes %lld-%lld/%lld\r\n",
                 start, end, size);
        qr_send_status(fd, 206, "Partial Content", ctype, cache, extra, end - start + 1);
    } else {
        qr_send_status(fd, 200, "OK", ctype, cache, NULL, size);
    }
    qr_pump_file(fd, fp, start, end);
    fclose(fp);
}

static int qr_safe_hls_name(const char *name)
{
    size_t len = strlen(name);
    if (len < 5 || len > 64) return 0;
    for (size_t i = 0; i < len; i++) {
        char c = name[i];
        if (!(isalnum((unsigned char)c) || c == '.' || c == '_' || c == '-'))
            return 0;
        if (c == '/' || c == '\\') return 0;
    }
    size_t el = len - 5;
    if (strcmp(name + el, ".m3u8") == 0) return 1;
    if (strcmp(name + len - 3, ".ts") == 0) return 1;
    return 0;
}

// returns malloc'd query value for key ("" if missing) or NULL
static char *qr_query_param(const char *query, const char *key)
{
    if (!query) return NULL;
    size_t klen = strlen(key);
    const char *p = query;
    while (p && *p) {
        const char *amp = strchr(p, '&');
        size_t seg = amp ? (size_t)(amp - p) : strlen(p);
        if (seg > klen && strncmp(p, key, klen) == 0 && p[klen] == '=') {
            size_t vlen = seg - klen - 1;
            char *v = (char *)malloc(vlen + 1);
            memcpy(v, p + klen + 1, vlen);
            v[vlen] = 0;
            return v;
        }
        p = amp ? amp + 1 : NULL;
    }
    return NULL;
}

// case-insensitive header lookup; returns malloc'd value or NULL
static char *qr_header_value(const char *req, const char *name)
{
    size_t nlen = strlen(name);
    const char *p = req;
    while (p && *p) {
        const char *eol = strstr(p, "\r\n");
        if (!eol) break;
        size_t linelen = (size_t)(eol - p);
        if (linelen > nlen + 1 && p[nlen] == ':' &&
            strncasecmp(p, name, nlen) == 0) {
            const char *v = p + nlen + 1;
            while (*v == ' ' || *v == '\t') v++;
            size_t vlen = (size_t)(eol - v);
            char *out = (char *)malloc(vlen + 1);
            memcpy(out, v, vlen);
            out[vlen] = 0;
            return out;
        }
        p = eol + 2;
    }
    return NULL;
}

#pragma mark - threading / routing

- (void)acceptLoop
{
    while (!_stopping) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int cfd = accept(_listenFd, (struct sockaddr *)&peer, &plen);
        if (cfd < 0) {
            if (_stopping) break;
            usleep(50000);
            continue;
        }
        struct timeval tv = { 30, 0 };
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        pthread_t t;
        if (pthread_create(&t, NULL, qr_conn_thread, (void *)(intptr_t)cfd) == 0)
            pthread_detach(t);
        else
            close(cfd);
    }
    [self release];
}

- (void)handleConn:(int)cfd
{
    char req[8192];
    size_t used = 0;
    req[0] = 0;
    while (used < sizeof(req) - 1) {
        ssize_t n = recv(cfd, req + used, sizeof(req) - 1 - used, 0);
        if (n <= 0) break;
        used += (size_t)n;
        req[used] = 0;
        if (strstr(req, "\r\n\r\n")) break;
    }
    req[used < sizeof(req) ? used : sizeof(req) - 1] = 0;

    char method[8] = {0}, target[2048] = {0}, version[16] = {0};
    if (sscanf(req, "%7s %2047s %15s", method, target, version) != 3 ||
        strcmp(method, "GET") != 0) {
        qr_send_status(cfd, 405, "Method Not Allowed", "text/plain", "no-cache", NULL, 0);
        close(cfd);
        return;
    }

    char *query = NULL;
    char *qmark = strchr(target, '?');
    if (qmark) { *qmark = 0; query = qmark + 1; }
    const char *path = target;

    if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0) {
        qr_serve_file(cfd, [_webDir stringByAppendingPathComponent:@"index.html"],
                      "text/html; charset=utf-8", "no-cache", NULL);
    } else if (strcmp(path, "/hls.min.js") == 0 || strcmp(path, "/hls.js") == 0) {
        qr_serve_file(cfd, [_webDir stringByAppendingPathComponent:@"hls.min.js"],
                      "application/javascript", "max-age=3600", NULL);
    } else if (strncmp(path, "/hls/", 5) == 0) {
        const char *name = path + 5;
        if (!qr_safe_hls_name(name)) {
            qr_send_status(cfd, 403, "Forbidden", "text/plain", "no-cache", NULL, 0);
        } else {
            size_t nl = strlen(name);
            const char *ctype = (strcmp(name + nl - 5, ".m3u8") == 0)
                ? qr_mime_m3u8 : qr_mime_ts;
            const char *cache = (strcmp(name + nl - 5, ".m3u8") == 0)
                ? "no-store, no-cache, must-revalidate" : "max-age=30";
            char *range = qr_header_value(req, "Range");
            qr_serve_file(cfd, [_hlsDir stringByAppendingPathComponent:
                      [NSString stringWithUTF8String:name]],
                      ctype, cache, range);
            if (range) free(range);
        }
    } else if (strcmp(path, "/switch") == 0) {
        char *c = qr_query_param(query, "c");
        QRCamera cam = (c && strcmp(c, "front") == 0) ? QRCameraFront : QRCameraRear;
        BOOL ok = YES;
        NSString *msg = nil;
        if (_engine) {
            NSError *err = nil;
            ok = [_engine switchTo:cam error:&err];
            if (!ok) msg = [err localizedDescription];
        } else {
            ok = NO;
            msg = @"no engine";
        }
        char body[512];
        int bl;
        if (ok) {
            bl = snprintf(body, sizeof(body), "{\"ok\":true,\"camera\":\"%s\"}",
                          cam == QRCameraFront ? "front" : "rear");
        } else {
            bl = snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"%s\"}",
                          msg ? [msg UTF8String] : "switch failed");
        }
        qr_send_status(cfd, ok ? 200 : 500, ok ? "OK" : "Error",
                       "application/json", "no-store", NULL, bl);
        qr_send_all(cfd, body, (size_t)bl);
        if (c) free(c);
    } else if (strcmp(path, "/toggle") == 0 || strcmp(path, "/start") == 0 ||
               strcmp(path, "/stop") == 0) {
        // used by the Activator tweak (localhost) and the web page
        BOOL cur = _engine && _engine.running;
        BOOL want = (strcmp(path, "/stop") == 0) ? NO
                  : (strcmp(path, "/start") == 0) ? YES : !cur;
        NSString *msg = nil;
        if (want != cur) {
            if (want) {
                NSError *e = nil;
                if (![_engine start:&e]) msg = [e localizedDescription];
            } else {
                [_proc stop];
                [_engine stop];
            }
        }
        BOOL streaming = _engine && _engine.running;
        const char *cam = (_engine && _engine.camera == QRCameraFront) ? "front" : "rear";
        char body[512];
        int bl;
        if (msg) {
            bl = snprintf(body, sizeof(body),
                "{\"ok\":false,\"streaming\":%s,\"error\":\"%s\"}",
                streaming ? "true" : "false",
                [msg UTF8String] ? [msg UTF8String] : "start failed");
        } else {
            bl = snprintf(body, sizeof(body),
                "{\"ok\":true,\"streaming\":%s,\"camera\":\"%s\"}",
                streaming ? "true" : "false", cam);
        }
        qr_send_status(cfd, msg ? 500 : 200, msg ? "Error" : "OK",
                       "application/json", "no-store", NULL, bl);
        qr_send_all(cfd, body, (size_t)bl);
    } else if (strcmp(path, "/status") == 0) {
        char body[512];
        const char *cam = (_engine && _engine.camera == QRCameraFront) ? "front" : "rear";
        snprintf(body, sizeof(body),
            "{\"camera\":\"%s\",\"fps\":%.1f,\"drops\":%lu,"
            "\"ffmpeg\":%s,\"pid\":%d,\"uptime\":%ld,\"streaming\":%s}",
            cam,
            _engine ? _engine.videoFps : 0.0,
            _engine ? (unsigned long)_engine.videoDrops : 0UL,
            (_proc && _proc.alive) ? "true" : "false",
            _proc ? (int)_proc.pid : -1,
            (long)(time(NULL) - _startedAt),
            (_engine && _engine.running) ? "true" : "false");
        qr_send_status(cfd, 200, "OK", "application/json", "no-store", NULL,
                       (long long)strlen(body));
        qr_send_all(cfd, body, strlen(body));
    } else {
        qr_send_status(cfd, 404, "Not Found", "text/plain", "no-cache", NULL, 0);
    }
    close(cfd);
}

@end

#pragma mark - thread trampolines

static void *qr_accept_thread(void *ctx)
{
    HttpServer *self = (HttpServer *)ctx;   // retained by creator
    [self acceptLoop];
    return NULL;
}

static void *qr_conn_thread(void *arg)
{
    // ctx is the raw fd; the HttpServer singleton is shared via a static ref
    extern HttpServer *qr_shared_server;
    if (qr_shared_server) [qr_shared_server handleConn:(int)(intptr_t)arg];
    close((int)(intptr_t)arg);
    return NULL;
}
