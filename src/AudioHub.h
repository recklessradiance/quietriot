#import <Foundation/Foundation.h>

// Broadcasts raw mic PCM to WebSocket clients as binary frames.
// send() is nonblocking; slow/stale clients are dropped so the audio
// capture thread never blocks.
@interface AudioHub : NSObject

- (void)addClient:(int)fd;
- (void)removeClient:(int)fd;
- (void)broadcast:(const void *)bytes length:(NSUInteger)len;
- (NSUInteger)clientCount;

@end
