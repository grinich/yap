#import <ZoomSDK/ZoomSDK.h>

// An original, brief shutter effect. Only these PCM samples enter the share channel.
@interface WHPhotoShutterAudio : NSObject <ZoomSDKShareAudioSourceDelegate>
@property(nonatomic, strong) ZoomSDKShareAudioSender *sender;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSData *pcm;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) BOOL playing;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSUInteger ticks;
@property(nonatomic, copy) void (^finished)(void);
@property(nonatomic, copy) void (^stopped)(void);
- (void)invalidate;
@end

@implementation WHPhotoShutterAudio
- (void)onStartSendAudio:(ZoomSDKShareAudioSender *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.invalidated) return;
        self.sender = sender;
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
            WHPhotoShutterAudio *audio = weakSelf;
            if (!audio || !audio.sender) { [timer invalidate]; return; }
            if (++audio.ticks >= 800) {
                audio.failed = YES;
                [audio.timer invalidate]; audio.timer = nil;
                if (audio.finished) audio.finished();
                return;
            }
            int16_t samples[441] = {0};
            if (audio.playing) {
                NSUInteger length = MIN(sizeof(samples), audio.pcm.length - audio.offset);
                if (length) memcpy(samples, (const char *)audio.pcm.bytes + audio.offset, length);
                audio.offset += length;
            }
            ZoomSDKError result = [audio.sender sendShareAudio:(char *)samples dataLength:sizeof(samples) sampleRate:44100 audioChannel:ZoomSDKAudioChannel_Mono];
            if (result != ZoomSDKError_Success) audio.failed = YES;
            if (result != ZoomSDKError_Success || (audio.playing && audio.offset >= audio.pcm.length)) {
                [audio.timer invalidate]; audio.timer = nil;
                if (audio.finished) audio.finished();
            }
        }];
    });
}
- (void)onStopSendAudio { dispatch_async(dispatch_get_main_queue(), ^{ [self invalidate]; if (self.stopped) self.stopped(); }); }
- (void)invalidate { self.invalidated = YES; [self.timer invalidate]; self.timer = nil; self.sender = nil; }
- (void)dealloc { [_timer invalidate]; }
@end
