#import "AudioHub.h"

#include <sys/socket.h>
#include <unistd.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define QR_MAX_WS_CLIENTS 24

@implementation AudioHub {
    pthread_mutex_t _lock;
    int _fds[QR_MAX_WS_CLIENTS];
    int _count;
    uint8_t *_out;      // shared frame buffer, used under _lock
    size_t _outCap;
}

- (id)init
{
    self = [super init];
    if (!self) return nil;
    pthread_mutex_init(&_lock, NULL);
    _count = 0;
    _out = NULL;
    _outCap = 0;
    return self;
}

- (void)dealloc
{
    pthread_mutex_lock(&_lock);
    for (int i = 0; i < _count; i++) close(_fds[i]);
    _count = 0;
    if (_out) { free(_out); _out = NULL; }
    pthread_mutex_unlock(&_lock);
    pthread_mutex_destroy(&_lock);
    [super dealloc];
}

- (void)addClient:(int)fd
{
    pthread_mutex_lock(&_lock);
    if (_count < QR_MAX_WS_CLIENTS) {
        _fds[_count++] = fd;
    } else {
        close(fd);
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeClient:(int)fd
{
    pthread_mutex_lock(&_lock);
    for (int i = 0; i < _count; i++) {
        if (_fds[i] == fd) {
            _fds[i] = _fds[--_count];
            break;
        }
    }
    pthread_mutex_unlock(&_lock);
}

- (NSUInteger)clientCount
{
    pthread_mutex_lock(&_lock);
    int c = _count;
    pthread_mutex_unlock(&_lock);
    return (NSUInteger)c;
}

- (void)broadcast:(const void *)bytes length:(NSUInteger)len
{
    if (!bytes || len == 0) return;
    pthread_mutex_lock(&_lock);

    size_t need = (size_t)len + 10;
    if (_outCap < need) {
        uint8_t *nbuf = (uint8_t *)realloc(_out, need);
        if (nbuf) { _out = nbuf; _outCap = need; }
        else { pthread_mutex_unlock(&_lock); return; }
    }

    // RFC 6455 binary frame, FIN set, unmasked (server -> client)
    size_t olen = 0;
    _out[olen++] = 0x82;
    if (len < 126) {
        _out[olen++] = (uint8_t)len;
    } else if (len <= 0xFFFF) {
        _out[olen++] = 126;
        _out[olen++] = (uint8_t)(len >> 8);
        _out[olen++] = (uint8_t)len;
    } else {
        _out[olen++] = 127;
        uint64_t l = (uint64_t)len;
        for (int i = 0; i < 8; i++)
            _out[olen++] = (uint8_t)(l >> (56 - i * 8));
    }
    memcpy(_out + olen, bytes, (size_t)len);
    olen += (size_t)len;

    int dead[QR_MAX_WS_CLIENTS];
    int ndead = 0;
    for (int i = 0; i < _count; i++) {
        ssize_t n = send(_fds[i], _out, olen, MSG_DONTWAIT);
        if (n != (ssize_t)olen)
            dead[ndead++] = _fds[i];
    }
    for (int i = 0; i < ndead; i++) {
        for (int j = 0; j < _count; j++) {
            if (_fds[j] == dead[i]) {
                close(dead[i]);
                _fds[j] = _fds[--_count];
                break;
            }
        }
    }
    pthread_mutex_unlock(&_lock);
}

@end
