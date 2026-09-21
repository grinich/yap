#import <AppKit/AppKit.h>
#import "WHPhotoShutterAudio.h"
@interface PhotoTestSender : NSObject
@property NSUInteger packets;
@property BOOL nonzero;
@property BOOL invalid;
@end
@implementation PhotoTestSender
- (ZoomSDKError)sendShareAudio:(char *)data dataLength:(unsigned int)length sampleRate:(int)rate audioChannel:(ZoomSDKAudioChannel)channel {
    self.packets++;
    if (length != 882 || rate != 44100 || channel != ZoomSDKAudioChannel_Mono) self.invalid = YES;
    for (unsigned int i = 0; i < length; i++) if (data[i]) self.nonzero = YES;
    return ZoomSDKError_Success;
}
@end
static BOOL waitUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        // Starting audio is queued on the main thread; its timer may not exist
        // until the first run-loop pass has already reached its deadline.
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}
int main(void) { @autoreleasepool {
    PhotoTestSender *sender = [PhotoTestSender new];
    WHPhotoShutterAudio *audio = [WHPhotoShutterAudio new];
    audio.pcm = [@"xx" dataUsingEncoding:NSUTF8StringEncoding];
    __block BOOL finished = NO;
    audio.finished = ^{ finished = YES; };
    [audio onStartSendAudio:(ZoomSDKShareAudioSender *)sender];
    NSCAssert(waitUntil(^BOOL{ return sender.packets > 0; }), @"Countdown must begin sending audio within one second");
    NSCAssert(sender.packets > 0 && !sender.nonzero && !sender.invalid, @"Countdown must transmit only correctly formatted silence");
    audio.playing = YES;
    NSCAssert(waitUntil(^{ return finished; }), @"Cue must finish within one second");
    NSCAssert(finished && sender.nonzero && !sender.invalid, @"Cue must send the supplied samples and finish");
    WHPhotoShutterAudio *cancelled = [WHPhotoShutterAudio new];
    PhotoTestSender *other = [PhotoTestSender new];
    [cancelled onStartSendAudio:(ZoomSDKShareAudioSender *)other];
    [cancelled invalidate];
    __block BOOL pendingStartProcessed = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ pendingStartProcessed = YES; });
    NSCAssert(waitUntil(^{ return pendingStartProcessed; }), @"Queued initialization must be processed within one second");
    NSCAssert(other.packets == 0 && cancelled.timer == nil && cancelled.sender == nil, @"Late initialization must not restart cancelled audio");
    puts("Shutter packet format, silent preparation, completion, and late cancellation passed.");
} return 0; }
