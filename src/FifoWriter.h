#import <Foundation/Foundation.h>

// Non-blocking FIFO writer used to feed ffmpeg through named pipes.
// Writers are opened O_RDWR|O_NONBLOCK so open() never blocks even before
// ffmpeg (the reader) has started, and we can drop frames under backpressure.

typedef struct {
    int fd;
    unsigned long drops;
} QRFifo;

BOOL qr_fifo_open(QRFifo *f, const char *path);
// Returns number of bytes written; -1 if the pipe was full (nothing written).
long qr_fifo_write(QRFifo *f, const void *buf, unsigned long len);
void qr_fifo_close(QRFifo *f);
