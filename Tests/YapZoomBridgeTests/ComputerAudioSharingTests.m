#import "YapZoomBridge.h"
#import <ZoomSDK/ZoomSDK.h>

@interface WHZoomSDKBridge (AudioTestHooks)
- (void)sharingStatus:(ZoomSDKShareStatus)status owner:(unsigned int)ownerID window:(uint32_t)windowID display:(uint32_t)displayID;
@end
@interface AudioTestBridge : WHZoomSDKBridge
@end
@implementation AudioTestBridge
- (void)refreshShares {} // No remote video views or live SDK session in this fixture.
@end
@interface AudioControllerFixture : NSObject
@property BOOL allowed;
@property NSInteger starts;
@property NSInteger stops;
@property ZoomSDKAudioShareMode mode;
@property ZoomSDKError startResult;
@end
@implementation AudioControllerFixture
- (BOOL)isAbleToShareComputerAudio { return self.allowed; }
- (ZoomSDKError)setAudioShareMode:(ZoomSDKAudioShareMode)mode { self.mode = mode; return ZoomSDKError_Success; }
- (ZoomSDKError)startAudioShare { self.starts++; return self.startResult; }
- (ZoomSDKError)stopShare { self.stops++; return ZoomSDKError_Success; }
@end
@interface MeetingFixture : NSObject
@property AudioControllerFixture *audio;
@end
@implementation MeetingFixture
- (id)getASController { return self.audio; }
- (id)getMeetingActionController { return nil; }
- (ZoomSDKMeetingStatus)getMeetingStatus { return ZoomSDKMeetingStatus_InMeeting; }
@end
static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        AudioTestBridge *bridge = [AudioTestBridge new];
        MeetingFixture *meeting = [MeetingFixture new];
        meeting.audio = [AudioControllerFixture new]; meeting.audio.allowed = YES;
        [bridge setValue:meeting forKey:@"meeting"];
        [bridge setValue:@"fixture-session" forKey:@"sessionID"];
        __block NSDictionary *lastShare;
        bridge.eventHandler = ^(NSString *session, NSString *event, NSData *data) {
            if ([event isEqual:@"sharing"]) lastShare = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        };
        Check([bridge startSharingComputerAudio] == ZoomSDKError_Success, @"audio-only request succeeds");
        Check(meeting.audio.starts == 1 && meeting.audio.mode == ZoomSDKAudioShareMode_Stereo, @"uses native stereo audio-only API");
        Check(lastShare == nil, @"request success alone never claims a broadcast");
        Check([bridge startSharingComputerAudio] != ZoomSDKError_Success, @"duplicate pending request is rejected");
        [bridge sharingStatus:ZoomSDKShareStatus_SelfStartAudioShare owner:0 window:0 display:0];
        Check([lastShare[@"active"] boolValue] && [lastShare[@"computerAudio"] boolValue], @"audio callback confirms sound, not a screen");
        Check([bridge startSharingWindow:42] != ZoomSDKError_Success && [bridge startSharingDisplay:42] != ZoomSDKError_Success, @"screen capture cannot silently replace active audio");
        [bridge sharingStatus:ZoomSDKShareStatus_OtherStopAudioShare owner:99 window:0 display:0];
        Check([lastShare[@"active"] boolValue], @"remote stop cannot clear local sound sharing");
        Check([bridge stopSharing] == ZoomSDKError_Success && meeting.audio.stops == 1, @"stop uses native stopShare");
        Check([lastShare[@"active"] boolValue], @"Stop remains available until confirmed");
        [bridge sharingStatus:ZoomSDKShareStatus_SelfStopAudioShare owner:0 window:0 display:0];
        Check(![lastShare[@"active"] boolValue], @"confirmed stop clears sharing");
        meeting.audio.startResult = ZoomSDKError_NoPermission;
        Check([bridge startSharingComputerAudio] == ZoomSDKError_NoPermission, @"SDK denial propagates");
        Check(![[bridge valueForKey:@"requestedComputerAudio"] boolValue], @"failed request can be retried");
        Check(![lastShare[@"active"] boolValue], @"denial does not claim an active share");
        [bridge sharingStatus:ZoomSDKShareStatus_SelfBegin owner:0 window:42 display:0];
        Check([lastShare[@"active"] boolValue] && ![lastShare[@"computerAudio"] boolValue], @"normal window sharing remains visual");
        Check([bridge startSharingComputerAudio] != ZoomSDKError_Success, @"audio-only cannot retain a live screen broadcast");
        [bridge sharingStatus:ZoomSDKShareStatus_SelfStopAudioShare owner:0 window:0 display:0];
        Check([lastShare[@"active"] boolValue], @"incidental audio stop cannot hide a screen share");
        puts("PASS: native computer-audio API, stereo, confirmed start/stop, failure recovery, and screen privacy guards");
    }
}
