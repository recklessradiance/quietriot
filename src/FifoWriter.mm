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
    while (done < len) {
        ssize_t n = write(f->fd, p + done, len - done);
        if (n > 0) {
            done += (unsigned long)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (done == 0) {
                f->drops++;
                return -1;
            }
            // partial write then full pipe: rare for our chunk sizes; treat as drop
            f->drops++;
            return -1;
        }
        if (n < 0 && errno == EINTR)
            continue;
        // real error
        f->drops++;
        return -1;
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
