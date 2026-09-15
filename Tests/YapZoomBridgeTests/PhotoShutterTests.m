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
static void pump(double seconds) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }
int main(void) { @autoreleasepool {
    PhotoTestSender *sender = [PhotoTestSender new];
    WHPhotoShutterAudio *audio = [WHPhotoShutterAudio new];
    audio.pcm = [@"xx" dataUsingEncoding:NSUTF8StringEncoding];
    __block BOOL finished = NO;
    audio.finished = ^{ finished = YES; };
    [audio onStartSendAudio:(ZoomSDKShareAudioSender *)sender];
    pump(0.05);
    NSCAssert(sender.packets > 0 && !sender.nonzero && !sender.invalid, @"Countdown must transmit only correctly formatted silence");
    audio.playing = YES; pump(0.05);
    NSCAssert(finished && sender.nonzero && !sender.invalid, @"Cue must send the supplied samples and finish");
    WHPhotoShutterAudio *cancelled = [WHPhotoShutterAudio new];
    PhotoTestSender *other = [PhotoTestSender new];
    [cancelled onStartSendAudio:(ZoomSDKShareAudioSender *)other];
    [cancelled invalidate]; pump(0.05);
    NSCAssert(other.packets == 0, @"Late initialization must not restart cancelled audio");
    puts("Shutter packet format, silent preparation, completion, and late cancellation passed.");
} return 0; }
