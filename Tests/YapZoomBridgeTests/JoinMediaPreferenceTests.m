#import "CameraEffectsFixture.h"

@interface WHZoomSDKBridge (JoinMediaFixture)
- (void)onMeetingStatusChange:(ZoomSDKMeetingStatus)state meetingError:(ZoomSDKMeetingError)error EndReason:(EndMeetingReason)reason;
- (void)onUserJoin:(NSArray *)array;
@end

@interface JoinMediaAudio : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) BOOL muted;
@property(nonatomic) BOOL ignoreMuteSetting;
@property(nonatomic) BOOL autoJoin;
@end
@implementation JoinMediaAudio
- (ZoomSDKError)enableMuteMicJoinVoip:(BOOL)enabled { if (!self.ignoreMuteSetting) self.muted = enabled; return ZoomSDKError_Success; }
- (BOOL)isMuteMicWhenJoinMeetingOn { return self.muted; }
- (ZoomSDKError)enableAutoJoinVoip:(BOOL)enabled { self.autoJoin = enabled; return ZoomSDKError_Success; }
- (ZoomSDKError)enablePushToTalk:(BOOL)enabled { return ZoomSDKError_Success; }
@end

@interface JoinMediaVideo : CameraVideoSetting
@property(nonatomic) BOOL muted;
@end
@implementation JoinMediaVideo
- (ZoomSDKError)disableVideoJoinMeeting:(BOOL)disabled { self.muted = disabled; return ZoomSDKError_Success; }
- (BOOL)isMuteMyVideoWhenJoinMeetingOn { return self.muted; }
- (ZoomSDKError)displayUserNameOnVideo:(BOOL)show { return ZoomSDKError_Success; }
- (BOOL)isdisplayUserNameOnVideoOn { return NO; }
- (BOOL)isStopIncomingVideoEnabled { return NO; }
- (ZoomSDKError)enableStopIncomingVideo:(BOOL)stop { return ZoomSDKError_Success; }
@end

@interface JoinMediaSharing : NSObject
@end
@implementation JoinMediaSharing
- (BOOL)isSupportShowZoomWindowWhenShare { return NO; }
- (ZoomSDKError)setShareOptionwWhenShareInDirectShare:(ZoomSDKSettingShareScreenShareOption)option { return ZoomSDKError_Success; }
@end

@interface JoinMediaSettings : CameraSettings
@property(nonatomic, strong) JoinMediaAudio *audio;
@property(nonatomic, strong) JoinMediaSharing *sharing;
@end
@implementation JoinMediaSettings
- (id)getAudioSetting { return self.audio; }
- (id)getShareScreenSetting { return self.sharing; }
@end

@interface JoinMediaDirectShare : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) NSUInteger starts;
@end
@implementation JoinMediaDirectShare
- (ZoomSDKError)canDirectShare { return ZoomSDKError_Success; }
- (ZoomSDKError)startDirectShare { self.starts++; return ZoomSDKError_Success; }
@end

@interface JoinMediaPremeeting : NSObject
@property(nonatomic) BOOL forceStart;
@property(nonatomic) BOOL forceStop;
@property(nonatomic, strong) JoinMediaDirectShare *directShare;
@end
@implementation JoinMediaPremeeting
- (ZoomSDKError)enableForceAutoStartMyVideoWhenJoinMeeting:(BOOL)enabled { self.forceStart = enabled; return ZoomSDKError_Success; }
- (ZoomSDKError)enableForceAutoStopMyVideoWhenJoinMeeting:(BOOL)enabled { self.forceStop = enabled; return ZoomSDKError_Success; }
- (ZoomSDKError)disableAutoShowSelectJoinAudioDlgWhenJoinMeeting:(BOOL)disabled { return ZoomSDKError_Success; }
- (id)getDirectShareHelper { return self.directShare; }
@end

@interface JoinMediaAuth : CameraAuth
@end
@implementation JoinMediaAuth
- (id)getAccountInfo { return nil; }
@end

@interface JoinMediaAction : CameraAction
@property(nonatomic, strong) JoinMediaAudio *audio;
@property(nonatomic) NSUInteger audioJoins;
@property(nonatomic) BOOL mutedAtAudioJoin;
@property(nonatomic) BOOL selfNotReady;
@property(nonatomic) ZoomSDKAudioType audioType;
@end
@implementation JoinMediaAction
- (id)getMyself { return self.selfNotReady ? nil : self; }
- (ZoomSDKAudioType)getAudioType { return self.audioType; }
- (ZoomSDKError)actionMeetingWithCmd:(ActionMeetingCmd)command userID:(unsigned int)userID onScreen:(ScreenType)screen {
    if (command == ActionMeetingCmd_JoinVoip) { self.audioJoins++; self.mutedAtAudioJoin = self.audio.muted; self.audioType = ZoomSDKAudioType_Voip; }
    return [super actionMeetingWithCmd:command userID:userID onScreen:screen];
}
@end

@interface JoinMediaMeeting : CameraMeeting
@property(nonatomic) BOOL enteredWithVideoOff;
@property(nonatomic) BOOL enteredWithAudioDisconnected;
@end
@implementation JoinMediaMeeting
- (ZoomSDKError)joinMeeting:(ZoomSDKJoinMeetingElements *)parameters {
    self.enteredWithVideoOff = parameters.isNoVideo; self.enteredWithAudioDisconnected = parameters.isNoAudio;
    return [super joinMeeting:parameters];
}
- (ZoomSDKError)startMeetingWithZAK:(ZoomSDKStartMeetingUseZakElements *)parameters {
    self.enteredWithVideoOff = parameters.isNoVideo; self.enteredWithAudioDisconnected = parameters.isNoAudio;
    return [super startMeetingWithZAK:parameters];
}
- (NSString *)getMeetingProperty:(MeetingPropertyCmd)property { return nil; }
@end

@interface JoinMediaSDK : CameraSDK
@property(nonatomic, strong) JoinMediaPremeeting *premeeting;
@end
@implementation JoinMediaSDK
- (id)getPremeetingService { return self.premeeting; }
@end

// Only collaborators are replaced. Begin, authorization, admission, camera
// enabling, and terminal cleanup execute the real bridge implementation.
@interface JoinMediaBridge : CameraGateBridge
@property(nonatomic, strong) NSMutableArray<NSString *> *errors;
@end
@implementation JoinMediaBridge
- (void)installMediaDeviceObserver {}
- (void)emitMediaDevices {}
- (void)refreshParticipants {}
- (void)refreshWaitingRoom {}
- (void)refreshShares {}
- (void)refreshChatNotice {}
- (void)refreshIndicators {}
- (void)refreshCloudRecording {}
- (void)startVideoStatistics {}
@end

static JoinMediaBridge *NewBridge(void) {
    JoinMediaSDK *sdk = [JoinMediaSDK new]; fixtureSDK = sdk;
    JoinMediaSettings *settings = [JoinMediaSettings new]; sdk.settings = settings;
    settings.audio = [JoinMediaAudio new]; settings.video = [JoinMediaVideo new]; settings.sharing = [JoinMediaSharing new];
    sdk.auth = [JoinMediaAuth new]; sdk.premeeting = [JoinMediaPremeeting new]; sdk.premeeting.directShare = [JoinMediaDirectShare new];
    JoinMediaMeeting *meeting = [JoinMediaMeeting new]; sdk.meeting = meeting; meeting.status = ZoomSDKMeetingStatus_Idle;
    JoinMediaAction *action = [JoinMediaAction new]; meeting.action = action; action.audio = settings.audio;
    JoinMediaBridge *bridge = [JoinMediaBridge new]; bridge.operations = [NSMutableArray array]; bridge.errors = [NSMutableArray array];
    action.operations = bridge.operations;
    __weak JoinMediaBridge *weakBridge = bridge;
    bridge.eventHandler = ^(NSString *session, NSString *event, NSData *data) {
        if ([event isEqualToString:@"controlError"] || [event isEqualToString:@"failure"]) [weakBridge.errors addObject:event];
    };
    return bridge;
}

static void Admit(JoinMediaBridge *bridge) {
    fixtureSDK.meeting.status = ZoomSDKMeetingStatus_InMeeting;
    [bridge onMeetingStatusChange:ZoomSDKMeetingStatus_InMeeting meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
}

static void Finish(JoinMediaBridge *bridge) {
    [bridge setValue:@NO forKey:@"directShareRunning"];
    fixtureSDK.meeting.status = ZoomSDKMeetingStatus_Ended;
    Check([bridge shutdown], @"the inert meeting ends and releases its SDK owner");
}

static AVAuthorizationStatus microphoneAuthorization = AVAuthorizationStatusAuthorized;
static AVAuthorizationStatus cameraAuthorization = AVAuthorizationStatusAuthorized;
static AVAuthorizationStatus MediaAuthorization(id receiver, SEL selector, AVMediaType mediaType) {
    return [mediaType isEqualToString:AVMediaTypeAudio] ? microphoneAuthorization : cameraAuthorization;
}

int main(void) {
    @autoreleasepool {
        Method shared = class_getClassMethod(ZoomSDK.class, @selector(sharedSDK));
        IMP original = method_setImplementation(shared, (IMP)FixtureSharedSDK);
        Method authorization = class_getClassMethod(AVCaptureDevice.class, @selector(authorizationStatusForMediaType:));
        IMP originalAuthorization = method_setImplementation(authorization, (IMP)MediaAuthorization);

        for (NSNumber *host in @[@NO, @YES]) for (NSNumber *quietly in @[@NO, @YES]) {
            JoinMediaBridge *bridge = NewBridge();
            JoinMediaSettings *settings = (id)fixtureSDK.settings;
            JoinMediaAction *action = (id)fixtureSDK.meeting.action;
            Check([bridge beginWithJWT:@"inert" zak:@"inert" meetingNumber:12345678901 vanityID:nil passcode:nil registrantToken:nil
                displayName:@"Fixture" host:host.boolValue microphoneMuted:quietly.boolValue cameraEnabled:!quietly.boolValue sessionID:@"fixture"] == 0,
                @"host and guest accept the captured preference");
            [bridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
            Check(fixtureSDK.meeting.joins == 1 && settings.audio.muted == quietly.boolValue && !settings.audio.autoJoin,
                @"authorization confirms the desired microphone entry state without starting audio");
            Check([(JoinMediaMeeting *)fixtureSDK.meeting enteredWithVideoOff] && [(JoinMediaMeeting *)fixtureSDK.meeting enteredWithAudioDisconnected] && action.audioJoins == 0 && action.unmutes == 0,
                @"SDK admission begins media-off until the guarded first-entry actions");
            [bridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
            Check(fixtureSDK.meeting.joins == 1, @"duplicate authentication cannot retry the meeting");
            [bridge onMeetingStatusChange:ZoomSDKMeetingStatus_AudioReady meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
            Check(settings.audio.muted == quietly.boolValue && action.audioJoins == 0,
                @"audio infrastructure readiness before admission cannot overwrite the requested mute state");
            Admit(bridge);
            Check(action.audioJoins == 1 && action.mutedAtAudioJoin == quietly.boolValue && action.unmutes == !quietly.boolValue,
                @"first admission alone applies the requested microphone and camera intent");
            if (!quietly.boolValue) Check([bridge.operations isEqualToArray:@[@"apply", @"unmute"]], @"background confirmation precedes camera transmission");
            [bridge onMeetingStatusChange:ZoomSDKMeetingStatus_AudioReady meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
            Check(settings.audio.muted, @"future audio attachments return to muted defaults without a live mute command");
            action.audioType = ZoomSDKAudioType_None;
            [bridge onMeetingStatusChange:ZoomSDKMeetingStatus_Reconnecting meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
            Admit(bridge); Admit(bridge);
            Check(action.audioJoins == 1 && action.unmutes == !quietly.boolValue, @"reconnection and duplicate admission never replay initial media intent");
            Check(bridge.errors.count == 0, @"the successful inert entry has no control errors");
            Finish(bridge);
        }

        JoinMediaBridge *room = NewBridge();
        Check([room beginRoomShareWithJWT:@"inert" sessionID:@"room"] == 0, @"room pairing begins independently");
        [room onZoomSDKAuthReturn:ZoomSDKAuthError_Success]; Admit(room);
        Check([(JoinMediaAction *)fixtureSDK.meeting.action audioJoins] == 0 && fixtureSDK.meeting.action.unmutes == 0 &&
            [(JoinMediaSettings *)fixtureSDK.settings audio].muted && ![(JoinMediaSettings *)fixtureSDK.settings audio].autoJoin,
            @"room sharing remains audio-disconnected and video-off");
        Finish(room);

        for (NSNumber *permissionDenied in @[@NO, @YES]) {
            JoinMediaBridge *guarded = NewBridge();
            guarded.applyResult = permissionDenied.boolValue ? 0 : ZoomSDKError_ServiceFailed;
            Check([guarded beginWithJWT:@"inert" zak:@"inert" meetingNumber:12345678901 vanityID:nil passcode:nil registrantToken:nil
                displayName:@"Fixture" host:NO microphoneMuted:NO cameraEnabled:YES sessionID:@"guard"] == 0, @"guard fixture begins");
            [guarded onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
            cameraAuthorization = permissionDenied.boolValue ? AVAuthorizationStatusDenied : AVAuthorizationStatusAuthorized;
            Admit(guarded);
            Check(fixtureSDK.meeting.action.unmutes == 0 && guarded.errors.count > 0, @"denied camera access or unconfirmed effects keep the camera off and report the error");
            Check([(JoinMediaAction *)fixtureSDK.meeting.action audioJoins] == 1, @"camera denial or effect failure does not prevent permitted meeting audio");
            cameraAuthorization = AVAuthorizationStatusAuthorized;
            guarded.applyResult = 0; Admit(guarded);
            Check(fixtureSDK.meeting.action.unmutes == 0, @"a later event cannot retry a rejected camera start");
            Finish(guarded);
        }

        JoinMediaBridge *microphoneDenied = NewBridge();
        Check([microphoneDenied beginWithJWT:@"inert" zak:@"inert" meetingNumber:12345678901 vanityID:nil passcode:nil registrantToken:nil
            displayName:@"Fixture" host:NO microphoneMuted:NO cameraEnabled:YES sessionID:@"microphone-denied"] == 0, @"microphone denial fixture begins");
        [microphoneDenied onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        microphoneAuthorization = AVAuthorizationStatusDenied; Admit(microphoneDenied);
        Check([(JoinMediaAction *)fixtureSDK.meeting.action audioJoins] == 0 && fixtureSDK.meeting.action.unmutes == 1,
            @"revoked microphone access leaves audio disconnected while permitted camera starts");
        microphoneAuthorization = AVAuthorizationStatusAuthorized; Admit(microphoneDenied);
        Check([(JoinMediaAction *)fixtureSDK.meeting.action audioJoins] == 0, @"restored microphone access does not cause an automatic retry");
        Finish(microphoneDenied);

        for (NSNumber *interrupted in @[@0, @1, @2]) {
            JoinMediaBridge *pending = NewBridge();
            JoinMediaAction *action = (id)fixtureSDK.meeting.action;
            Check([pending beginWithJWT:@"inert" zak:@"inert" meetingNumber:12345678901 vanityID:nil passcode:nil registrantToken:nil
                displayName:@"Fixture" host:NO microphoneMuted:NO cameraEnabled:YES sessionID:@"pending-self"] == 0, @"deferred self fixture begins");
            [pending onZoomSDKAuthReturn:ZoomSDKAuthError_Success]; action.selfNotReady = YES; Admit(pending);
            Check(action.audioJoins == 0 && action.unmutes == 0, @"missing local roster never consumes or starts media");
            if (interrupted.intValue == 1) [pending onMeetingStatusChange:ZoomSDKMeetingStatus_Reconnecting meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
            if (interrupted.intValue == 2) [pending setCameraEnabled:NO];
            fixtureSDK.meeting.status = ZoomSDKMeetingStatus_AudioReady;
            action.selfNotReady = NO; [pending onUserJoin:@[@1]];
            Check(action.audioJoins == 1 && action.unmutes == (interrupted.intValue == 0 ? 1 : 0) && action.mutedAtAudioJoin == (interrupted.intValue != 0),
                @"a late self record permits playback, while reconnect or explicit media control cancels deferred camera/unmute intent");
            Finish(pending);
        }

        JoinMediaBridge *unconfirmed = NewBridge();
        [(JoinMediaSettings *)fixtureSDK.settings audio].ignoreMuteSetting = YES;
        Check([unconfirmed beginWithJWT:@"inert" zak:@"inert" meetingNumber:12345678901 vanityID:nil passcode:nil registrantToken:nil
            displayName:@"Fixture" host:NO microphoneMuted:YES cameraEnabled:NO sessionID:@"unconfirmed"] == 0, @"readback fixture begins");
        [unconfirmed onZoomSDKAuthReturn:ZoomSDKAuthError_Success]; DrainMainQueue();
        Check(fixtureSDK.meeting.joins == 0 && unconfirmed.errors.count > 0, @"failed muted-entry readback prevents joining");
        Finish(unconfirmed);
        method_setImplementation(authorization, originalAuthorization);
        method_setImplementation(shared, original);
        puts("PASS: host/guest media preference, quiet room share, one-shot admission, permission/effects guards, and mute readback");
    }
    return 0;
}
