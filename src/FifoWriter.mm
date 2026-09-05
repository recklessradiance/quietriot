#import "FifoWriter.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <stdio.h>

BOOL qr_fifo_open(QRFifo *f, const char *path)
{
    f->fd = -1;
    f->drops = 0;
    unlink(path);
    if (mkfifo(path, 0600) != 0 && errno != EEXIST)
        return NO;
    // O_RDWR keeps open() from blocking when ffmpeg hasn't opened the read
    // end yet, and lets us drop instead of stall under backpressure.
    f->fd = open(path, O_RDWR | O_NONBLOCK);
    if (f->fd < 0)
        return NO;
    return YES;
}

long qr_fifo_write(QRFifo *f, const void *buf, unsigned long len)
{
    if (f->fd < 0)
        return -1;
    const char *p = (const char *)buf;
    unsigned long done = 0;
    int blocked = 0;
    while (done < len) {
        ssize_t n = write(f->fd, p + done, len - done);
        if (n > 0) {
            done += (unsigned long)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (done == 0) {
                // nothing of this frame in the pipe yet: cheap drop, capture
                // keeps flowing while ffmpeg is absent/slow
                f->drops++;
                return -1;
            }
            // mid-frame: MUST finish (rawvideo reads fixed-size blocks).
            // Don't poll-wait: iOS 6 fifos appear not to wake poll() on
            // writability. A blocking write sleeps on the pipe condition
            // and wakes immediately when the reader drains space.
            if (!blocked) {
                int fl = fcntl(f->fd, F_GETFL);
                fcntl(f->fd, F_SETFL, fl & ~O_NONBLOCK);
                blocked = 1;
            }
            continue;
        }
        if (blocked) {
            int fl = fcntl(f->fd, F_GETFL);
            fcntl(f->fd, F_SETFL, fl | O_NONBLOCK);
        }
        // real error (EPIPE etc.)
        f->drops++;
        return -1;
    }
    if (blocked) {
        int fl = fcntl(f->fd, F_GETFL);
        fcntl(f->fd, F_SETFL, fl | O_NONBLOCK);
    }
    return (long)len;
}

void qr_fifo_close(QRFifo *f)
{
    if (f->fd >= 0) {
        close(f->fd);
        f->fd = -1;
    }
}
