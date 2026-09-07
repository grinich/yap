#import "YapZoomBridge.h"
#import <ZoomSDK/ZoomSDK.h>
#import <os/log.h>
#import <math.h>
#import "WHZoomRenderHost.h"
#import "WHZoomVideoDetachGrace.h"
#import "WHZoomCloudRecordingPolicy.h"
#import "WHZoomShareStatus.h"

static BOOL WHZoomStatusIsTerminal(ZoomSDKMeetingStatus status) {
    return status == ZoomSDKMeetingStatus_Idle || status == ZoomSDKMeetingStatus_Ended || status == ZoomSDKMeetingStatus_Failed;
}

static os_log_t WHZoomConnectionLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("app.yap.zoom", "connection"); });
    return log;
}

static NSString *WHZoomErrorName(ZoomSDKError error) {
    switch (error) {
        case ZoomSDKError_Success: return @"Success";
        case ZoomSDKError_Failed: return @"Failed";
        case ZoomSDKError_Uninit: return @"Uninitialized";
        case ZoomSDKError_ServiceFailed: return @"ServiceFailed";
        case ZoomSDKError_WrongUsage: return @"WrongUsage";
        case ZoomSDKError_InvalidParameter: return @"InvalidParameter";
        case ZoomSDKError_NoPermission: return @"NoPermission";
        case ZoomSDKError_TooFrequentCall: return @"TooFrequentCall";
        case ZoomSDKError_UnSupportedFeature: return @"UnsupportedFeature";
        case ZoomSDKError_ModuleLoadFail: return @"ModuleLoadFail";
        default: return @"Error";
    }
}

@interface WHZoomSDKBridge () <ZoomSDKAuthDelegate, ZoomSDKMeetingServiceDelegate,
    ZoomSDKMeetingActionControllerDelegate, ZoomSDKMeetingChatControllerDelegate,
    ZoomSDKASControllerDelegate, ZoomSDKWaitingRoomDelegate, ZoomSDKVideoContainerDelegate,
    ZoomSDKReminderControllerDelegate, ZoomSDKMeetingIndicatorControllerDelegate,
    ZoomSDKMeetingRecordDelegate>
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, strong) ZoomSDKMeetingService *meeting;
@property(nonatomic, strong) ZoomSDKJoinMeetingElements *joinParameters;
@property(nonatomic, strong) ZoomSDKStartMeetingUseZakElements *hostParameters;
@property(nonatomic) BOOL initialized;
@property(nonatomic) BOOL joinRequested;
@property(nonatomic) BOOL ending;
@property(nonatomic) BOOL hosting;
@property(nonatomic) BOOL hasEnteredMeeting;
@property(nonatomic) BOOL terminalStatusObserved;
@property(nonatomic) BOOL connectionWatchdogArmed;
@property(nonatomic) NSUInteger connectionWatchdogRevision;
@property(nonatomic) NSUInteger leaveWatchdogRevision;
@property(nonatomic) BOOL leaveWatchdogArmed;
@property(nonatomic) BOOL leaveWarningEmitted;
@property(nonatomic) NSTimeInterval leaveStartedAt;
@property(nonatomic) ZoomSDKMeetingStatus lastLeaveStatus;
@property(nonatomic, copy) NSString *terminationMessage;
@property(nonatomic) BOOL updatingVisibleParticipants;
@property(nonatomic) BOOL localShareActive;
@property(nonatomic) BOOL awaitingShareSource;
@property(nonatomic) NSUInteger shareSourceRevision;
@property(nonatomic) uint32_t requestedShareWindowID;
@property(nonatomic) uint32_t requestedShareDisplayID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZoomSDKNormalVideoElement *> *videos;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WHZoomRenderHost *> *videoHosts;
@property(nonatomic, strong) NSMutableSet<NSString *> *subscribedVideos;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *requestedAvatars;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *avatarRevisions;
@property(nonatomic, strong) NSNumber *profilePicturesHidden;
@property(nonatomic, strong) WHZoomVideoDetachGrace *videoDetachGrace;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *videoRetryAttempts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSUUID *> *videoRetryTokens;
@property(nonatomic, strong) NSMutableSet<NSString *> *videoRetryExhausted;
@property(nonatomic, strong) NSTimer *videoStatisticsTimer;
@property(nonatomic, strong) NSTimer *videoSizeTimer;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *participantVideoSizes;
@property(nonatomic, strong) ZoomSDKShareElement *shareElement;
@property(nonatomic, strong) WHZoomRenderHost *shareHost;
@property(nonatomic, copy) NSString *selectedShareID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZoomSDKMeetingIndicatorHandle *> *indicators;
@property(nonatomic, strong) ZoomSDKMeetingAppsignalHandler *appSignal;
@property(nonatomic, strong) NSMutableArray<NSAlert *> *alerts;
@property(nonatomic, copy) NSDictionary *lastCloudRecordingPayload;
@property(nonatomic, strong) NSUUID *cloudRecordingStartRequest;
@property(nonatomic) unsigned int cloudRecordingRequesterID;
@end

@implementation WHZoomSDKBridge
- (instancetype)init {
    if ((self = [super init])) {
        _videos = [NSMutableDictionary dictionary]; _videoHosts = [NSMutableDictionary dictionary];
        _subscribedVideos = [NSMutableSet set];
        _requestedAvatars = [NSMutableSet set]; _avatarRevisions = [NSMutableDictionary dictionary];
        _participantVideoSizes = [NSMutableDictionary dictionary];
        _videoDetachGrace = [WHZoomVideoDetachGrace new];
        _videoRetryAttempts = [NSMutableDictionary dictionary];
        _videoRetryTokens = [NSMutableDictionary dictionary]; _videoRetryExhausted = [NSMutableSet set];
        _indicators = [NSMutableDictionary dictionary]; _alerts = [NSMutableArray array];
    }
    return self;
}

- (void)onMain:(dispatch_block_t)operation {
    if (NSThread.isMainThread) operation();
    else dispatch_async(dispatch_get_main_queue(), operation);
}

- (void)emit:(NSString *)event object:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:NSJSONWritingFragmentsAllowed error:nil];
    if (!data) return;
    [self onMain:^{
        if (self.sessionID && self.eventHandler) self.eventHandler(self.sessionID, event, data);
    }];
}

// Every caller supplies a fixed phase label. Never pass SDK payloads or user data to this logger.
- (void)logConnection:(const char *)phase code:(NSInteger)code status:(NSInteger)status reason:(NSInteger)reason {
    os_log_info(WHZoomConnectionLog(), "phase=%{public}s code=%{public}ld status=%{public}ld reason=%{public}ld host=%{public}d joinRequested=%{public}d ending=%{public}d notices=%{public}lu",
                phase, (long)code, (long)status, (long)reason, self.hosting, self.joinRequested, self.ending, (unsigned long)self.alerts.count);
}

- (void)cancelConnectionWatchdog {
    self.connectionWatchdogArmed = NO;
    self.connectionWatchdogRevision += 1;
}

- (void)armConnectionWatchdog {
    if (!self.sessionID || self.ending || !self.joinRequested || self.hasEnteredMeeting || self.alerts.count || self.connectionWatchdogArmed) return;
    self.connectionWatchdogArmed = YES;
    NSUInteger revision = ++self.connectionWatchdogRevision;
    NSString *session = [self.sessionID copy];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || ![self.sessionID isEqualToString:session] || self.connectionWatchdogRevision != revision || !self.connectionWatchdogArmed) return;
        self.connectionWatchdogArmed = NO;
        ZoomSDKMeetingStatus state = [self.meeting getMeetingStatus];
        [self logConnection:"connection-watchdog-getter" code:0 status:state reason:0];
        if (self.ending || self.hasEnteredMeeting || self.alerts.count) return;
        if (state == ZoomSDKMeetingStatus_InMeeting || state == ZoomSDKMeetingStatus_WaitingForHost || state == ZoomSDKMeetingStatus_InWaitingRoom) {
            // The getter can advance without its delegate callback. Reconcile authoritative state.
            [self logConnection:"getter-state-reconciled" code:0 status:state reason:0];
            [self onMeetingStatusChange:state meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
            return;
        }
        if (state == ZoomSDKMeetingStatus_AudioReady) {
            self.hasEnteredMeeting = YES;
            [self logConnection:"getter-audio-ready-without-meeting" code:0 status:state reason:0];
            [self emit:@"controlError" object:@"Zoom reports that audio is ready, but hasn’t confirmed the meeting state. The session remains open; you can leave if it does not finish connecting."];
            return;
        }
        [self logConnection:"connection-timeout" code:0 status:state reason:0];
        [self requestLeaveWithMessage:@"Zoom’s meeting connection timed out. Please try again." endMeeting:NO];
    });
}

- (void)updateConnectionWatchdogForStatus:(ZoomSDKMeetingStatus)state {
    if (state == ZoomSDKMeetingStatus_Connecting && !self.alerts.count) [self armConnectionWatchdog];
    else [self cancelConnectionWatchdog];
}

- (BOOL)canSafelyResetNative {
    if (!self.meeting) return !self.joinRequested;
    return self.terminalStatusObserved || WHZoomStatusIsTerminal([self.meeting getMeetingStatus]);
}

- (void)checkLeaveCompletion:(NSUInteger)revision session:(NSString *)session {
    if (!self.leaveWatchdogArmed || self.leaveWatchdogRevision != revision || ![self.sessionID isEqualToString:session]) return;
    ZoomSDKMeetingStatus state = [self.meeting getMeetingStatus];
    if ([self canSafelyResetNative]) { [self terminateWithMessage:self.terminationMessage]; return; }
    if (state != self.lastLeaveStatus) {
        self.lastLeaveStatus = state;
        [self logConnection:"leave-status" code:0 status:state reason:0];
    }
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.leaveStartedAt;
    if (elapsed >= 15 && !self.leaveWarningEmitted) {
        self.leaveWarningEmitted = YES;
        [self logConnection:"leave-unconfirmed" code:0 status:state reason:0];
        [self emit:@"controlError" object:@"Zoom hasn’t confirmed that it disconnected. Yap is keeping the meeting session open and will keep checking."];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((elapsed < 15 ? 0.5 : 2.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf checkLeaveCompletion:revision session:session];
    });
}

- (void)requestLeaveWithMessage:(NSString *)message endMeeting:(BOOL)end {
    if (!self.sessionID) return;
    if (message && !self.terminationMessage) self.terminationMessage = message;
    self.ending = YES;
    [self cancelConnectionWatchdog];
    if ([self canSafelyResetNative]) { [self terminateWithMessage:self.terminationMessage]; return; }
    [self emit:@"status" object:@"leaving"];
    if (message) [self emit:@"controlError" object:[message stringByAppendingString:@" Yap is asking Zoom to disconnect before closing this meeting."]];
    if (self.leaveWatchdogArmed) return;
    self.leaveWatchdogArmed = YES;
    self.leaveWarningEmitted = NO;
    self.leaveStartedAt = NSProcessInfo.processInfo.systemUptime;
    self.lastLeaveStatus = [self.meeting getMeetingStatus];
    NSUInteger revision = ++self.leaveWatchdogRevision;
    NSString *session = [self.sessionID copy];
    [self logConnection:"leave-request" code:0 status:self.lastLeaveStatus reason:0];
    [self.meeting leaveMeetingWithCmd:end ? LeaveMeetingCmd_End : LeaveMeetingCmd_Leave];
    [self checkLeaveCompletion:revision session:session];
}

- (NSInteger)beginWithJWT:(NSString *)jwt zak:(NSString *)zak meetingNumber:(int64_t)meetingNumber
                vanityID:(NSString *)vanityID passcode:(NSString *)passcode
         registrantToken:(NSString *)registrantToken displayName:(NSString *)displayName
                    host:(BOOL)host sessionID:(NSString *)sessionID {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    if (self.sessionID) return ZoomSDKError_WrongUsage;
    self.sessionID = sessionID; self.ending = NO; self.joinRequested = NO; self.hosting = host;
    self.hasEnteredMeeting = NO; self.terminalStatusObserved = NO; self.terminationMessage = nil;
    ZoomSDKInitParams *params = [ZoomSDKInitParams new];
    params.needCustomizedUI = YES; params.enableLog = NO; params.zoomDomain = @"zoom.us";
    ZoomSDKError result = [[ZoomSDK sharedSDK] initSDKWithParams:params];
    [self logConnection:"init-return" code:result status:0 reason:0];
    if (result != ZoomSDKError_Success) { self.sessionID = nil; return result; }
    self.initialized = YES;
    [[ZoomSDK sharedSDK] getReminderHelper].delegate = self;
    if (host) {
        ZoomSDKStartMeetingUseZakElements *context = [ZoomSDKStartMeetingUseZakElements new];
        context.zak = zak; context.displayName = displayName; context.meetingNumber = meetingNumber;
        context.vanityID = vanityID;
        // Hosting uses the real meeting number returned by the REST create-meeting API.
        context.userType = SDKUserType_APIUser;
        context.isNoVideo = YES; context.isNoAudio = YES;
        self.hostParameters = context;
    } else {
        ZoomSDKJoinMeetingElements *context = [ZoomSDKJoinMeetingElements new];
        context.zak = zak; context.displayName = displayName; context.meetingNumber = meetingNumber;
        context.vanityID = vanityID; context.password = passcode; context.webinarToken = registrantToken;
        context.userType = ZoomSDKUserType_WithoutLogin; context.isNoVideo = YES; context.isNoAudio = YES;
        self.joinParameters = context;
    }
    ZoomSDKAuthService *auth = [[ZoomSDK sharedSDK] getAuthService];
    auth.delegate = self;
    ZoomSDKAuthContext *context = [ZoomSDKAuthContext new]; context.jwtToken = jwt;
    result = [auth sdkAuth:context];
    [self logConnection:"auth-request-return" code:result status:0 reason:0];
    if (result != ZoomSDKError_Success) { [self resetNative]; self.sessionID = nil; return result; }
    NSString *pending = [sessionID copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([self.sessionID isEqualToString:pending] && !self.joinRequested && !self.ending) {
            [self terminateWithMessage:@"Zoom authentication timed out. Please try again."];
        }
    });
    return ZoomSDKError_Success;
}

- (void)onZoomSDKAuthReturn:(ZoomSDKAuthError)result {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onZoomSDKAuthReturn:result]; }); return; }
    if (!self.sessionID || self.ending || self.joinRequested) return;
    [self logConnection:"auth-result" code:result status:0 reason:0];
    if (result != ZoomSDKAuthError_Success) {
        [self terminateWithMessage:[NSString stringWithFormat:@"Zoom could not authenticate this app (SDK code %ld). Check your developer credentials.", (long)result]];
        return;
    }
    self.meeting = [[ZoomSDK sharedSDK] getMeetingService];
    if (!self.meeting) { [self terminateWithMessage:@"Zoom’s meeting service could not start."]; return; }
    // SDK services are guaranteed usable only after authorization succeeds.
    // Refuse to join if Zoom cannot confirm muted-on-entry, before any media starts.
    ZoomSDKAudioSetting *audio = [[[ZoomSDK sharedSDK] getSettingService] getAudioSetting];
    if (!audio || [audio enableMuteMicJoinVoip:YES] != ZoomSDKError_Success || ![audio isMuteMicWhenJoinMeetingOn]) {
        [self terminateWithMessage:@"Zoom could not confirm a muted microphone before joining. Please try again."];
        return;
    }
    [audio enableAutoJoinVoip:NO];
    [audio enablePushToTalk:NO];
    ZoomSDKVideoSetting *video = [[[ZoomSDK sharedSDK] getSettingService] getVideoSetting];
    // Yap supplies one accessible participant label and microphone indicator.
    // Configure Zoom's combined native name/mute decoration before creating views.
    ZoomSDKError labelResult = video ? [video displayUserNameOnVideo:NO] : ZoomSDKError_ServiceFailed;
    [self logConnection:"hide-sdk-video-label" code:labelResult status:[video isdisplayUserNameOnVideoOn] reason:0];
    BOOL incomingWasStopped = [video isStopIncomingVideoEnabled];
    ZoomSDKError incomingResult = [video enableStopIncomingVideo:NO];
    [self logConnection:"allow-incoming-video" code:incomingResult status:[video isStopIncomingVideoEnabled] reason:incomingWasStopped];
    ZoomSDKShareScreenSetting *sharing = [[[ZoomSDK sharedSDK] getSettingService] getShareScreenSetting];
    if ([sharing isSupportShowZoomWindowWhenShare]) {
        // This documented setting covers Zoom's meeting windows. Custom floating
        // panels still require receiver-side verification; it is not an exclusion API.
        ZoomSDKError sharingResult = [sharing setShowZoomWindowWhenShare:NO];
        [self logConnection:"hide-sdk-windows-when-sharing" code:sharingResult status:[sharing isShowZoomWindowWhenShare] reason:0];
    }
    self.meeting.delegate = self;
    [self.meeting getMeetingActionController].delegate = self;
    [self.meeting getMeetingChatController].delegate = self;
    [self.meeting getWaitingRoomController].delegate = self;
    [self.meeting getVideoContainer].delegate = self;
    [self.meeting getMeetingIndicatorController].delegate = self;
    [self.meeting getRecordController].delegate = self;
    BOOL isHost = self.hostParameters != nil;
    ZoomSDKMeetingStatus initialState = [self.meeting getMeetingStatus];
    BOOL sdkLoggedIn = [[[ZoomSDK sharedSDK] getAuthService] getAccountInfo] != nil;
    self.joinRequested = YES;
    [self armConnectionWatchdog];
    ZoomSDKError error = self.hostParameters ? [self.meeting startMeetingWithZAK:self.hostParameters] : [self.meeting joinMeeting:self.joinParameters];
    ZoomSDKMeetingStatus returnedState = [self.meeting getMeetingStatus];
    [self logConnection:isHost ? "start-return" : "join-return" code:error status:returnedState reason:0];
    self.hostParameters = nil; self.joinParameters = nil;
    if (error != ZoomSDKError_Success) {
        self.joinRequested = NO;
        [self terminateWithMessage:[NSString stringWithFormat:
            @"Zoom could not %@ the meeting (SDK %@, code %ld; meeting state %ld; SDK login %@).",
            isHost ? @"start" : @"join", WHZoomErrorName(error), (long)error, (long)initialState,
            sdkLoggedIn ? @"present" : @"absent"]];
    } else if (self.sessionID && !self.ending && !self.hasEnteredMeeting && returnedState == ZoomSDKMeetingStatus_InMeeting) {
        [self logConnection:"start-getter-state-reconciled" code:0 status:returnedState reason:0];
        [self onMeetingStatusChange:returnedState meetingError:ZoomSDKMeetingError_Success EndReason:EndMeetingReason_None];
    }
}
- (void)onZoomAuthIdentityExpired {
    [self emit:@"controlError" object:@"Zoom’s app authentication expired. Reconnect before your next meeting."];
}

- (void)leaveEndingMeeting:(BOOL)end {
    if (!self.sessionID || self.ending) return;
    [self requestLeaveWithMessage:nil endMeeting:end];
}

- (void)terminateWithMessage:(NSString *)message {
    if (!self.sessionID) return;
    if (message && !self.terminationMessage) self.terminationMessage = message;
    if (![self canSafelyResetNative]) { [self requestLeaveWithMessage:self.terminationMessage endMeeting:NO]; return; }
    self.ending = YES;
    [self cancelConnectionWatchdog];
    NSString *session = [self.sessionID copy];
    // Leave the SDK delegate stack before uninitializing its native objects.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.sessionID isEqualToString:session]) return;
        if (![self canSafelyResetNative]) { [self requestLeaveWithMessage:self.terminationMessage endMeeting:NO]; return; }
        NSString *finalMessage = self.terminationMessage;
        [self logConnection:"terminal-cleanup" code:0 status:self.meeting ? [self.meeting getMeetingStatus] : 0 reason:0];
        [self resetNative];
        if (finalMessage) [self emit:@"failure" object:finalMessage];
        else [self emit:@"status" object:@"idle"];
        self.sessionID = nil;
    });
}

- (void)resetNative {
    [self.requestedAvatars removeAllObjects]; [self.avatarRevisions removeAllObjects];
    self.profilePicturesHidden = nil;
    self.cloudRecordingStartRequest = nil; self.cloudRecordingRequesterID = 0;
    self.lastCloudRecordingPayload = nil;
    self.localShareActive = NO; self.awaitingShareSource = NO; self.shareSourceRevision += 1;
    self.requestedShareWindowID = 0; self.requestedShareDisplayID = 0;
    [self.videoStatisticsTimer invalidate]; self.videoStatisticsTimer = nil;
    [self.videoSizeTimer invalidate]; self.videoSizeTimer = nil;
    [self.participantVideoSizes removeAllObjects];
    [self cancelConnectionWatchdog];
    self.leaveWatchdogArmed = NO; self.leaveWatchdogRevision += 1;
    [self setVisibleParticipants:@[]]; [self selectReceivedShare:nil];
    for (NSAlert *alert in [self.alerts copy]) {
        if (alert.window.sheetParent) [alert.window.sheetParent endSheet:alert.window returnCode:NSAlertSecondButtonReturn];
    }
    [self.alerts removeAllObjects];
    self.meeting.delegate = nil;
    [self.meeting getMeetingActionController].delegate = nil;
    [self.meeting getMeetingChatController].delegate = nil;
    [self.meeting getASController].delegate = nil;
    [self.meeting getWaitingRoomController].delegate = nil;
    [self.meeting getVideoContainer].delegate = nil;
    [self.meeting getMeetingIndicatorController].delegate = nil;
    [self.meeting getRecordController].delegate = nil;
    if (self.initialized) {
        [[ZoomSDK sharedSDK] getAuthService].delegate = nil;
        [[ZoomSDK sharedSDK] getReminderHelper].delegate = nil;
        [[ZoomSDK sharedSDK] unInitSDK];
    }
    self.initialized = NO; self.joinRequested = NO; self.meeting = nil;
    self.joinParameters = nil; self.hostParameters = nil; self.appSignal = nil;
    self.terminationMessage = nil; self.hasEnteredMeeting = NO; self.terminalStatusObserved = NO;
    [self.indicators removeAllObjects];
}

- (void)onMeetingStatusChange:(ZoomSDKMeetingStatus)state meetingError:(ZoomSDKMeetingError)error EndReason:(EndMeetingReason)reason {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self onMeetingStatusChange:state meetingError:error EndReason:reason]; }); return;
    }
    if (!self.sessionID) return;
    self.terminalStatusObserved = WHZoomStatusIsTerminal(state);
    [self logConnection:"meeting-status" code:error status:state reason:reason];
    [self updateConnectionWatchdogForStatus:state];
    switch (state) {
        case ZoomSDKMeetingStatus_Idle:
        case ZoomSDKMeetingStatus_Ended: [self terminateWithMessage:nil]; break;
        case ZoomSDKMeetingStatus_Failed:
            [self terminateWithMessage:[NSString stringWithFormat:@"Zoom could not complete the meeting connection (meeting code %ld).", (long)error]]; break;
        case ZoomSDKMeetingStatus_Connecting: [self emit:@"status" object:@"connecting"]; break;
        case ZoomSDKMeetingStatus_WaitingForHost: [self emit:@"status" object:@"waitingForHost"]; break;
        case ZoomSDKMeetingStatus_InWaitingRoom: [self emit:@"status" object:@"waitingRoom"]; break;
        case ZoomSDKMeetingStatus_Disconnecting:
            self.cloudRecordingStartRequest = nil; [self emit:@"status" object:@"leaving"]; break;
        case ZoomSDKMeetingStatus_Reconnecting:
            self.cloudRecordingStartRequest = nil; [self emit:@"status" object:@"reconnecting"]; break;
        case ZoomSDKMeetingStatus_InMeeting:
            self.hasEnteredMeeting = YES;
            if (self.ending) { [self.meeting leaveMeetingWithCmd:LeaveMeetingCmd_Leave]; break; }
            {
                // Zoom creates the sharing controller only after admission. The
                // pre-join authentication callback is too early to set its delegate.
                ZoomSDKASController *share = [self.meeting getASController];
                share.delegate = self;
                os_log_info(WHZoomConnectionLog(), "share=delegate controllerPresent=%{public}d delegateInstalled=%{public}d",
                    share != nil, share.delegate == self);
                // Like sharing, recording services may be created on admission.
                [self.meeting getRecordController].delegate = self;
            }
            [self emit:@"status" object:@"inMeeting"];
            [self refreshParticipants]; [self refreshWaitingRoom]; [self refreshShares]; [self refreshChatNotice];
            [self refreshIndicators];
            [self refreshCloudRecording];
            [self startVideoStatistics];
            {
                NSString *invitation = [self.meeting getMeetingProperty:MeetingPropertyCmd_JoinMeetingUrl];
                if (invitation.length) [self emit:@"invitation" object:invitation];
                // Connect playback while keeping the input muted through Zoom's join-VoIP setting.
                ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
                if ([[action getMyself] getAudioType] == ZoomSDKAudioType_None) {
                    [action actionMeetingWithCmd:ActionMeetingCmd_JoinVoip userID:0 onScreen:ScreenType_First];
                }
            }
            break;
        case ZoomSDKMeetingStatus_AudioReady: [self refreshParticipants]; break;
        default: break;
    }
}

- (NSValue *)videoSizeForUser:(unsigned int)userID cameraEnabled:(BOOL)enabled {
    NSNumber *identifier = @(userID);
    if (!enabled) { [self.participantVideoSizes removeObjectForKey:identifier]; return nil; }
    CGSize size = [self.meeting getUserVideoSize:userID];
    if (isfinite(size.width) && isfinite(size.height) && size.width >= 1 && size.height >= 1 &&
        size.width <= 16384 && size.height <= 16384 && size.width / size.height >= 0.125 && size.width / size.height <= 8) {
        self.participantVideoSizes[identifier] = [NSValue valueWithSize:size];
    }
    // Zoom may briefly report zero while a stream starts or rotates. Preserve
    // the last usable dimensions until new frames arrive or the camera stops.
    return self.participantVideoSizes[identifier];
}
- (void)refreshVisibleVideoSizes {
    if (!self.hasEnteredMeeting || !self.sessionID || self.ending) return;
    BOOL changed = NO;
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    for (NSString *identifier in self.subscribedVideos.allObjects) {
        unsigned int userID = identifier.intValue;
        NSValue *previous = self.participantVideoSizes[@(userID)];
        NSValue *current = [self videoSizeForUser:userID cameraEnabled:[[action getUserByUserID:userID] isVideoOn]];
        if (previous != current && ![previous isEqual:current]) changed = YES;
    }
    if (changed) [self refreshParticipants];
}
- (void)refreshParticipants {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshParticipants]; }); return; }
    if (!self.meeting || self.ending) return;
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    NSMutableArray *people = [NSMutableArray array];
    NSArray<NSNumber *> *identifiers = [action getParticipantsList] ?: @[];
    NSSet *currentIDs = [NSSet setWithArray:identifiers];
    [self.requestedAvatars intersectSet:currentIDs];
    for (NSNumber *identifier in self.avatarRevisions.allKeys) {
        if (![currentIDs containsObject:identifier]) [self.avatarRevisions removeObjectForKey:identifier];
    }
    for (NSNumber *identifier in self.participantVideoSizes.allKeys) {
        if (![currentIDs containsObject:identifier]) [self.participantVideoSizes removeObjectForKey:identifier];
    }
    BOOL picturesHidden = self.profilePicturesHidden ? self.profilePicturesHidden.boolValue : [action isParticipantProfilePicturesHidden];
    NSMutableArray<NSNumber *> *avatarRequests = [NSMutableArray array];
    for (NSNumber *identifier in identifiers) {
        ZoomSDKUserInfo *user = [action getUserByUserID:identifier.unsignedIntValue];
        if (!user) continue;
        ZoomSDKAudioStatus audio = [user getAudioStatus];
        BOOL muted = !(audio == ZoomSDKAudioStatus_UnMuted || audio == ZoomSDKAudioStatus_UnMutedByHost || audio == ZoomSDKAudioStatus_UnMutedAllByHost);
        NSMutableDictionary *person = [@{@"id":@([user getUserID]).stringValue, @"name":[user getUserName] ?: @"Participant",
                           @"isSelf":@([user isMySelf]), @"isHost":@([user isHost]), @"isMuted":@(muted),
                           @"isCameraEnabled":@([user isVideoOn]), @"isSpeaking":@([user isTalking])} mutableCopy];
        NSValue *videoSize = [self videoSizeForUser:identifier.unsignedIntValue cameraEnabled:[user isVideoOn]];
        if (videoSize) {
            person[@"videoWidth"] = @(videoSize.sizeValue.width);
            person[@"videoHeight"] = @(videoSize.sizeValue.height);
        }
        if (!picturesHidden) {
            NSString *path = [user getAvatarPath];
            if (path.length) {
                person[@"avatarPath"] = path;
                person[@"avatarRevision"] = self.avatarRevisions[identifier] ?: @0;
            }
            if (self.hasEnteredMeeting && ![self.requestedAvatars containsObject:identifier]) {
                // Mark before requesting: the SDK may synchronously call back.
                [self.requestedAvatars addObject:identifier];
                [avatarRequests addObject:identifier];
            }
        }
        [people addObject:person];
    }
    [self emit:@"participants" object:people];
    // Emit first so a synchronous avatar callback cannot be overwritten by
    // the older roster. Zoom owns downloading; we only consume its local file.
    for (NSNumber *identifier in avatarRequests) {
        if (self.ending || self.profilePicturesHidden.boolValue) break;
        ZoomSDKError result = [action requestAvatarForUser:identifier.unsignedIntValue];
        [self logConnection:"avatar-request" code:result status:0 reason:0];
    }
}
- (void)onUserJoin:(NSArray *)array { [self refreshParticipants]; }
- (void)onUserLeft:(NSArray *)array { [self refreshParticipants]; [self refreshShares]; }
- (void)onUserNamesChanged:(NSArray *)array { [self refreshParticipants]; }
- (void)onUserAudioStatusChange:(NSArray *)array { [self refreshParticipants]; }
- (void)onVideoStatusChange:(ZoomSDKVideoStatus)status UserID:(unsigned int)userID {
    [self onMain:^{
        if (!self.sessionID || self.ending) return;
        NSString *identifier = @(userID).stringValue;
        ZoomSDKNormalVideoElement *element = self.videos[identifier];
        if (element) {
            [self logVideo:"camera-status" element:element code:status];
            if (![[[self.meeting getMeetingActionController] getUserByUserID:userID] isVideoOn]) {
                BOOL wasSubscribed = [self.subscribedVideos containsObject:identifier];
                [self.subscribedVideos removeObject:identifier];
                if (wasSubscribed) { [element subscribeVideo:NO]; [element showVideo:NO]; }
                [self.videoRetryAttempts removeObjectForKey:identifier];
                [self.videoRetryTokens removeObjectForKey:identifier];
                [self.videoRetryExhausted removeObject:identifier];
            }
            [self.videoHosts[identifier] scheduleRendererUpdate];
        }
        [self refreshParticipants]; [self refreshVideoStatistics];
    }];
}
- (void)onUserActiveAudioChange:(NSArray *)array { [self refreshParticipants]; }
- (void)onHostChange:(unsigned int)userID { [self refreshParticipants]; [self refreshWaitingRoom]; [self refreshCloudRecording]; }
- (void)onMeetingCoHostChanged:(unsigned int)userID isCoHost:(BOOL)isCoHost { [self refreshParticipants]; [self refreshCloudRecording]; }

- (NSInteger)setMicrophoneMuted:(BOOL)muted {
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    if (!action) return ZoomSDKError_WrongUsage;
    return [action actionMeetingWithCmd:muted ? ActionMeetingCmd_MuteAudio : ActionMeetingCmd_UnMuteAudio userID:0 onScreen:ScreenType_First];
}
- (NSInteger)setCameraEnabled:(BOOL)enabled {
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    if (!action) return ZoomSDKError_WrongUsage;
    if (enabled) {
        // Request HD only after the person explicitly turns on their camera.
        ZoomSDKVideoSetting *video = [[[ZoomSDK sharedSDK] getSettingService] getVideoSetting];
        ZoomSDKError hdResult = video ? [video enableCatchHDVideo:YES] : ZoomSDKError_ServiceFailed;
        [self logConnection:"request-hd-camera" code:hdResult status:[video isCatchHDVideoOn] reason:0];
    }
    ZoomSDKError result = [action actionMeetingWithCmd:enabled ? ActionMeetingCmd_UnMuteVideo : ActionMeetingCmd_MuteVideo userID:0 onScreen:ScreenType_First];
    [self refreshVideoStatistics];
    return result;
}
- (void)startVideoStatistics {
    if (self.videoStatisticsTimer) return;
    __weak typeof(self) weakSelf = self;
    self.videoStatisticsTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshVideoStatistics];
    }];
    // The native renderer has no dimension-change callback. Query only mounted
    // streams and emit a new roster only on a change (for example phone rotation).
    self.videoSizeTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshVisibleVideoSizes];
    }];
    self.videoSizeTimer.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:self.videoSizeTimer forMode:NSRunLoopCommonModes];
    [self refreshVideoStatistics];
}
- (void)refreshVideoStatistics {
    if (!self.sessionID || self.ending || !self.hasEnteredMeeting) return;
    [self refreshCloudRecording];
    ZoomSDKSettingService *settings = [[ZoomSDK sharedSDK] getSettingService];
    ZoomSDKASVStatisticInfo *statistics = [[settings getStatisticsSetting] getVideoStatisticInfo];
    BOOL cameraOn = [[[self.meeting getMeetingActionController] getMyself] isVideoOn];
    // Zoom's resolution value packs width in the low 16 bits, height in the high 16.
    uint32_t sent = cameraOn ? (uint32_t)statistics.sendResolution : 0;
    uint32_t received = (uint32_t)statistics.recvResolution;
    BOOL hd = [[settings getVideoSetting] isCatchHDVideoOn];
    [self emit:@"videoQuality" object:@{@"requestsHD":@(hd), @"sendWidth":@(sent & 0xffff),
        @"sendHeight":@(sent >> 16), @"sendFPS":@(cameraOn ? statistics.sendFps : 0)}];
    os_log_info(WHZoomConnectionLog(), "video=statistics available=%{public}d hdRequested=%{public}d camera=%{public}d sendPacked=%{public}u sendWidth=%{public}u sendHeight=%{public}u sendFPS=%{public}ld sendBandwidth=%{public}ld receivePacked=%{public}u receiveWidth=%{public}u receiveHeight=%{public}u receiveFPS=%{public}ld receiveBandwidth=%{public}ld",
        statistics != nil, hd, cameraOn, sent, sent & 0xffff, sent >> 16, (long)statistics.sendFps, (long)statistics.sendBandwidth,
        received, received & 0xffff, received >> 16, (long)statistics.recvFps, (long)statistics.recvBandwidth);
}
- (NSInteger)sendChatText:(NSString *)text {
    ZoomSDKMeetingChatController *chat = [self.meeting getMeetingChatController];
    if (!chat) return ZoomSDKError_WrongUsage;
    ZoomSDKChatMsgInfoBuilder *builder = [ZoomSDKChatMsgInfoBuilder new];
    ZoomSDKChatInfo *message = [[[[builder setContent:text] setReceiver:0] setMessageType:ZoomSDKChatMessageType_To_All] build];
    if (!message) return ZoomSDKError_WrongUsage;
    return [chat sendChatMsgTo:message];
}
- (BOOL)hasCloudRecordingControlRole {
    ZoomSDKUserInfo *myself = [[self.meeting getMeetingActionController] getMyself];
    return myself && ([myself isHost] || [myself getUserRole] == UserRole_CoHost);
}
- (BOOL)isConnectedForCloudRecording {
    return self.sessionID != nil && !self.ending && self.hasEnteredMeeting &&
        [self.meeting getMeetingStatus] == ZoomSDKMeetingStatus_InMeeting;
}
- (void)publishCloudRecordingStatus:(ZoomSDKRecordingStatus)status {
    if (!self.sessionID || self.ending) return;
    ZoomSDKMeetingRecordController *record = [self.meeting getRecordController];
    ZoomSDKError permission = record ? [record canStartRecording:YES] : ZoomSDKError_ServiceFailed;
    if (!record || ![self isConnectedForCloudRecording] || ![self hasCloudRecordingControlRole])
        self.cloudRecordingStartRequest = nil;
    NSDictionary *payload = WHZoomCloudRecordingPayload(status, permission,
        record && [self isConnectedForCloudRecording], [self hasCloudRecordingControlRole]);
    if (![payload isEqualToDictionary:self.lastCloudRecordingPayload]) {
        self.lastCloudRecordingPayload = payload;
        [self emit:@"cloudRecording" object:payload];
        os_log_info(WHZoomConnectionLog(), "recording=status status=%{public}ld permission=%{public}ld controls=%{public}d",
            (long)status, (long)permission, [payload[@"canControl"] boolValue]);
    }
}
- (void)refreshCloudRecording {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshCloudRecording]; }); return; }
    if (!self.sessionID || self.ending || !self.hasEnteredMeeting) return;
    ZoomSDKMeetingRecordController *record = [self.meeting getRecordController];
    if (record.delegate != self) record.delegate = self;
    [self publishCloudRecordingStatus:record ? [record getCloudRecordingStatus] : ZoomSDKRecordingStatus_None];
}
- (NSInteger)performCloudRecordingAction:(WHZoomCloudRecordingAction)action {
    if (!NSThread.isMainThread) return ZoomSDKError_WrongUsage;
    ZoomSDKMeetingRecordController *record = [self.meeting getRecordController];
    ZoomSDKRecordingStatus status = record ? [record getCloudRecordingStatus] : ZoomSDKRecordingStatus_None;
    ZoomSDKError permission = record ? [record canStartRecording:YES] : ZoomSDKError_ServiceFailed;
    ZoomSDKError validation = WHZoomCloudRecordingCommandError(action, status, permission,
        record && [self isConnectedForCloudRecording], [self hasCloudRecordingControlRole]);
    if (validation != ZoomSDKError_Success) { [self refreshCloudRecording]; return validation; }
    record.delegate = self;
    NSUUID *request = nil;
    if (action == WHZoomCloudRecordingActionStart) {
        if (self.cloudRecordingStartRequest) return ZoomSDKError_TooFrequentCall;
        request = NSUUID.UUID;
        self.cloudRecordingStartRequest = request;
        self.cloudRecordingRequesterID = [[[self.meeting getMeetingActionController] getMyself] getUserID];
        NSString *session = [self.sessionID copy];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if ([self.sessionID isEqualToString:session] && [self.cloudRecordingStartRequest isEqual:request]) self.cloudRecordingStartRequest = nil;
        });
    }
    ZoomSDKError result;
    switch (action) {
        case WHZoomCloudRecordingActionStart: result = [record startCloudRecording:YES]; break;
        case WHZoomCloudRecordingActionStop: result = [record startCloudRecording:NO]; break;
        case WHZoomCloudRecordingActionPause: result = [record pauseCloudRecording]; break;
        case WHZoomCloudRecordingActionResume: result = [record resumeCloudRecording]; break;
    }
    if (result != ZoomSDKError_Success && [self.cloudRecordingStartRequest isEqual:request]) self.cloudRecordingStartRequest = nil;
    os_log_info(WHZoomConnectionLog(), "recording=command action=%{public}ld code=%{public}ld", (long)action, (long)result);
    // A successful command means accepted, not that recording has started.
    [self refreshCloudRecording];
    return result;
}
- (NSInteger)setCloudRecordingEnabled:(BOOL)enabled {
    return [self performCloudRecordingAction:enabled ? WHZoomCloudRecordingActionStart : WHZoomCloudRecordingActionStop];
}
- (NSInteger)pauseCloudRecording { return [self performCloudRecordingAction:WHZoomCloudRecordingActionPause]; }
- (NSInteger)resumeCloudRecording { return [self performCloudRecordingAction:WHZoomCloudRecordingActionResume]; }
- (BOOL)consumeCloudRecordingStartRequestFrom:(unsigned int)requesterID {
    if (!self.cloudRecordingStartRequest || ![self isConnectedForCloudRecording] || ![self hasCloudRecordingControlRole] ||
        requesterID == 0 || requesterID != self.cloudRecordingRequesterID ||
        requesterID != [[[self.meeting getMeetingActionController] getMyself] getUserID]) return NO;
    self.cloudRecordingStartRequest = nil;
    return YES;
}
- (void)finishCloudRecordingRequestWithResult:(ZoomSDKError)result {
    if (result != ZoomSDKError_Success) [self emit:@"cloudRecordingError" object:[NSString stringWithFormat:
        @"Zoom could not start standard cloud recording (SDK %@, code %ld).", WHZoomErrorName(result), (long)result]];
    [self refreshCloudRecording];
}
- (void)onChatMessageNotification:(ZoomSDKChatInfo *)chat { [self publishChat:chat event:@"chat"]; }
- (void)publishChat:(ZoomSDKChatInfo *)chat event:(NSString *)event {
    NSDictionary *snapshot = @{@"id":[[chat getMessageID] copy] ?: @"", @"senderName":[[chat getSenderDisplayName] copy] ?: @"Participant",
        @"text":[[chat getMsgContent] copy] ?: @"", @"timestamp":@([chat getTimeStamp]),
        @"senderID":@([chat getSenderUserID])};
    [self onMain:^{
        NSMutableDictionary *message = [snapshot mutableCopy];
        message[@"isFromSelf"] = @([message[@"senderID"] unsignedIntValue] == [[[self.meeting getMeetingActionController] getMyself] getUserID]);
        [self emit:event object:message];
    }];
}
- (void)refreshChatNotice {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshChatNotice]; }); return; }
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    if ([action isMeetingChatLegalNoticeAvailable]) {
        [self emit:@"chatLegalNotice" object:@{@"prompt":[action getChatLegalNoticesPrompt] ?: @"",
            @"explanation":[action getChatLegalNoticesExplained] ?: @""}];
    } else [self emit:@"chatLegalNotice" object:NSNull.null];
}
- (void)onCloudRecordingStatus:(ZoomSDKRecordingStatus)status {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!session || ![self.sessionID isEqualToString:session] || self.ending) return;
        if (status != ZoomSDKRecordingStatus_Connecting && status != ZoomSDKRecordingStatus_None) self.cloudRecordingStartRequest = nil;
        [self publishCloudRecordingStatus:status];
        [self refreshChatNotice];
        if (status == ZoomSDKRecordingStatus_DiskFull) [self emit:@"cloudRecordingError" object:@"Zoom stopped cloud recording because storage is full. Manage the host’s cloud recording storage in Zoom."];
        else if (status == ZoomSDKRecordingStatus_Fail) [self emit:@"cloudRecordingError" object:@"Zoom could not save the cloud recording. Check the host’s recording storage and account settings before trying again."];
    }];
}
- (void)onLocalRecordStatus:(ZoomSDKRecordingStatus)status userID:(unsigned int)userID { [self refreshChatNotice]; }
- (void)onChatStatusChangedNotification:(ZoomSDKChatStatus *)status { [self refreshChatNotice]; }

- (void)refreshWaitingRoom {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshWaitingRoom]; }); return; }
    ZoomSDKWaitingRoomController *waiting = [self.meeting getWaitingRoomController];
    NSMutableArray *people = [NSMutableArray array];
    for (NSNumber *identifier in [waiting getWaitRoomUserList] ?: @[]) {
        ZoomSDKUserInfo *user = [waiting getWaitingRoomUserInfo:identifier.unsignedIntValue];
        if (user) [people addObject:@{@"id":@([user getUserID]).stringValue, @"name":[user getUserName] ?: @"Participant"}];
    }
    [self emit:@"waitingRoom" object:people];
}
- (void)onUserJoinWaitingRoom:(unsigned int)userID { [self refreshWaitingRoom]; }
- (void)onUserLeftWaitingRoom:(unsigned int)userID { [self refreshWaitingRoom]; }
- (void)onWaitingRoomUserNameChanged:(unsigned int)userID userName:(NSString *)name { [self refreshWaitingRoom]; }
- (NSInteger)admitParticipant:(uint32_t)participantID {
    ZoomSDKWaitingRoomController *waiting = [self.meeting getWaitingRoomController];
    return waiting ? [waiting admitToMeeting:participantID] : ZoomSDKError_WrongUsage;
}

// Logs contain geometry and SDK result codes only, never names, meeting IDs or media.
- (void)logVideo:(const char *)phase element:(ZoomSDKVideoElement *)element code:(NSInteger)code {
    if (!element || !self.sessionID) return;
    NSString *identifier = [self.videos allKeysForObject:(id)element].firstObject;
    if (!identifier) return; // Ignore callbacks from an element already cleaned up.
    WHZoomRenderHost *host = self.videoHosts[identifier];
    ZoomSDKUserInfo *user = [[self.meeting getMeetingActionController] getUserByUserID:element.userid];
    os_log_info(WHZoomConnectionLog(), "video=%{public}s code=%{public}ld type=%{public}ld self=%{public}d camera=%{public}d window=%{public}d ready=%{public}d width=%{public}.0f height=%{public}.0f layer=%{public}d",
        phase, (long)code, (long)[element getDataType], [user isMySelf], [user isVideoOn], host.window != nil,
        host.isReadyForRenderer, host.bounds.size.width, host.bounds.size.height, element.videoView.wantsLayer);
}
- (void)reconcileVideo:(NSString *)identifier ready:(BOOL)ready {
    if (!self.sessionID || self.ending) return;
    ZoomSDKNormalVideoElement *element = self.videos[identifier];
    if (!element) return;
    BOOL subscribed = [self.subscribedVideos containsObject:identifier];
    BOOL cameraOn = [[[self.meeting getMeetingActionController] getUserByUserID:(unsigned int)identifier.longLongValue] isVideoOn];
    if (!cameraOn) {
        [self.videoDetachGrace detachImmediately:identifier action:^{ [self suspendVideo:identifier element:element]; }];
        return;
    }
    if (!ready) {
        if (!subscribed) return;
        NSString *session = [self.sessionID copy];
        __weak typeof(self) weakSelf = self;
        __weak ZoomSDKNormalVideoElement *weakElement = element;
        BOOL scheduled = [self.videoDetachGrace scheduleIdentifier:identifier action:^{
            typeof(self) self = weakSelf;
            ZoomSDKNormalVideoElement *element = weakElement;
            if (!self || !element || self.ending || ![self.sessionID isEqualToString:session] || self.videos[identifier] != element) return;
            BOOL cameraOn = [[[self.meeting getMeetingActionController] getUserByUserID:(unsigned int)identifier.longLongValue] isVideoOn];
            if (self.videoHosts[identifier].isReadyForRenderer && cameraOn) {
                [self logVideo:"handoff-preserved" element:element code:0];
                return;
            }
            [self suspendVideo:identifier element:element];
        }];
        if (scheduled) [self logVideo:"detach-pending" element:element code:200];
        return;
    }
    if ([self.videoDetachGrace cancelIdentifier:identifier] && subscribed) [self logVideo:"handoff-preserved" element:element code:0];
    if (subscribed) return;
    // Bind after the participant's camera-on view has joined a window. Eager binding
    // on onUserJoin can precede Zoom's video readiness (including admission).
    [self.subscribedVideos addObject:identifier]; // guards synchronous SDK callbacks
    unsigned int userID = (unsigned int)identifier.longLongValue;
    if (element.userid != userID) {
        // Setting userid starts Zoom's subscription itself. An immediate explicit
        // subscribeVideo:YES duplicates it; our live 7.1.5 run reported reason 7.
        ZoomSDKError shown = [element showVideo:YES];
        [self logVideo:"show-initial" element:element code:shown];
        element.userid = userID;
        [self logVideo:"bind-user" element:element code:0];
    } else {
        // A bound, suspended renderer needs one immediate resume. The retry
        // delay is only for actual rate limiting, not every foreground return.
        NSString *session = [self.sessionID copy];
        ZoomSDKError result = [element showVideo:YES];
        [self logVideo:"show-resumed" element:element code:result];
        if (self.ending || ![self.sessionID isEqualToString:session] || self.videos[identifier] != element ||
            ![self.subscribedVideos containsObject:identifier] || !self.videoHosts[identifier].isReadyForRenderer) return;
        if (result == ZoomSDKError_Success) {
            // A synchronous SDK failure callback may already have queued its
            // rate-limit retry. Do not add another request to that burst.
            if (self.videoRetryTokens[identifier] || [self.videoRetryExhausted containsObject:identifier]) return;
            result = [element subscribeVideo:YES];
            [self logVideo:"subscribe-resumed" element:element code:result];
        }
        if (self.ending || ![self.sessionID isEqualToString:session] || self.videos[identifier] != element ||
            ![self.subscribedVideos containsObject:identifier]) return;
        if (result == ZoomSDKError_TooFrequentCall) [self scheduleVideoRetry:identifier element:element];
        else if (result != ZoomSDKError_Success) {
            [self emit:@"controlError" object:[NSString stringWithFormat:@"Zoom could not resume a video (SDK %@, code %ld).", WHZoomErrorName(result), (long)result]];
        }
    }
}
- (void)suspendVideo:(NSString *)identifier element:(ZoomSDKNormalVideoElement *)element {
    if (self.videos[identifier] != element || ![self.subscribedVideos containsObject:identifier]) return;
    [self.subscribedVideos removeObject:identifier];
    [self.videoRetryTokens removeObjectForKey:identifier];
    [self.videoRetryAttempts removeObjectForKey:identifier];
    [self.videoRetryExhausted removeObject:identifier];
    [element subscribeVideo:NO]; [element showVideo:NO];
    [self logVideo:"detached" element:element code:0];
}
- (void)scheduleVideoRetry:(NSString *)identifier element:(ZoomSDKNormalVideoElement *)element {
    if (!self.sessionID || self.ending || self.videos[identifier] != element ||
        ![self.subscribedVideos containsObject:identifier] || !self.videoHosts[identifier].isReadyForRenderer ||
        self.videoRetryTokens[identifier] != nil || [self.videoRetryExhausted containsObject:identifier]) return;
    NSUInteger attempt = [self.videoRetryAttempts[identifier] unsignedIntegerValue];
    if (attempt >= 3) {
        [self.videoRetryExhausted addObject:identifier];
        [self emit:@"controlError" object:@"Zoom kept rate-limiting an incoming video after three spaced retries. Turn that participant’s camera off and on, or rejoin the meeting."];
        return;
    }
    NSUUID *token = [NSUUID UUID];
    self.videoRetryTokens[identifier] = token;
    NSTimeInterval delay = 1.5 * (1 << attempt);
    NSString *session = [self.sessionID copy];
    __weak typeof(self) weakSelf = self;
    __weak ZoomSDKNormalVideoElement *weakElement = element;
    [self logVideo:"retry-scheduled" element:element code:attempt + 1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        ZoomSDKNormalVideoElement *element = weakElement;
        [self performVideoRetry:identifier element:element session:session token:token attempt:attempt];
    });
}
- (void)performVideoRetry:(NSString *)identifier element:(ZoomSDKNormalVideoElement *)element session:(NSString *)session token:(NSUUID *)token attempt:(NSUInteger)attempt {
    if (!element || ![self.sessionID isEqualToString:session] || self.videos[identifier] != element ||
        ![self.videoRetryTokens[identifier] isEqual:token]) return;
    // A retry already due during a handoff must not be dropped. Preserve its
    // token/attempt for one grace interval; genuine detach clears that token.
    if (!self.ending && !self.videoHosts[identifier].isReadyForRenderer && [self.videoDetachGrace hasPendingIdentifier:identifier]) {
        __weak typeof(self) weakSelf = self;
        __weak ZoomSDKNormalVideoElement *weakElement = element;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf performVideoRetry:identifier element:weakElement session:session token:token attempt:attempt];
        });
        return;
    }
    [self.videoRetryTokens removeObjectForKey:identifier];
    if (self.ending || ![self.subscribedVideos containsObject:identifier] || !self.videoHosts[identifier].isReadyForRenderer ||
        ![[[self.meeting getMeetingActionController] getUserByUserID:element.userid] isVideoOn]) return;
    self.videoRetryAttempts[identifier] = @(attempt + 1);
    ZoomSDKError result = [element subscribeVideo:YES];
    [self logVideo:"subscribe-retry" element:element code:result];
    if (result == ZoomSDKError_TooFrequentCall) [self scheduleVideoRetry:identifier element:element];
    else if (result != ZoomSDKError_Success) {
        [self emit:@"controlError" object:[NSString stringWithFormat:@"Zoom could not resume an incoming video (SDK %@, code %ld).", WHZoomErrorName(result), (long)result]];
    }
}
- (void)setVisibleParticipants:(NSArray<NSString *> *)participantIDs {
    if (self.updatingVisibleParticipants) return;
    self.updatingVisibleParticipants = YES;
    @try {
        ZoomSDKVideoContainer *container = [self.meeting getVideoContainer];
        NSSet *visible = [NSSet setWithArray:participantIDs];
        for (NSString *identifier in self.videos.allKeys) {
            if (![visible containsObject:identifier]) {
                ZoomSDKNormalVideoElement *element = self.videos[identifier];
                WHZoomRenderHost *host = self.videoHosts[identifier];
                host.resizeRenderer = nil; host.reconcileRenderer = nil;
                [self.subscribedVideos removeObject:identifier];
                [self.videoRetryAttempts removeObjectForKey:identifier];
                [self.videoRetryTokens removeObjectForKey:identifier]; [self.videoRetryExhausted removeObject:identifier];
                // Drop identity before SDK cleanup can synchronously call its delegate.
                [self.videos removeObjectForKey:identifier]; [self.videoHosts removeObjectForKey:identifier];
                [self.videoDetachGrace detachImmediately:identifier action:^{
                    [element subscribeVideo:NO]; [element showVideo:NO];
                    [element.videoView removeFromSuperview]; [container cleanVideoElement:element];
                }];
            }
        }
        if (!container || self.ending) return;
        for (NSString *identifier in participantIDs) {
            if (self.videos[identifier]) continue;
            ZoomSDKNormalVideoElement *element = [[ZoomSDKNormalVideoElement alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
            ZoomSDKError result = [container createNormalVideoElement:&element];
            if (result != ZoomSDKError_Success || !element) {
                [self emit:@"controlError" object:@"Zoom could not display every selected video. Try a smaller gallery page."];
                break;
            }
            // Let Zoom adapt to each renderer's current geometry. A creation-only
            // resolution cap survives element reuse when a grid tile becomes the
            // focused video. Setting resolution can also restart a subscription.
            WHZoomRenderHost *host = [[WHZoomRenderHost alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
            NSView *view = [element getVideoView];
            if (view) {
                view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                [host addSubview:view];
            }
            __weak ZoomSDKNormalVideoElement *weakElement = element;
            __weak typeof(self) weakSelf = self;
            host.resizeRenderer = ^(NSRect bounds) {
                ZoomSDKNormalVideoElement *element = weakElement;
                if (!element) return;
                ZoomSDKError result = [element resize:bounds];
                [weakSelf logVideo:"resize" element:element code:result];
            };
            host.reconcileRenderer = ^(BOOL ready) { [weakSelf reconcileVideo:identifier ready:ready]; };
            self.videos[identifier] = element; self.videoHosts[identifier] = host;
            [host scheduleRendererUpdate];
        }
    } @finally { self.updatingVisibleParticipants = NO; }
}
- (NSView *)videoViewForParticipant:(NSString *)participantID { return self.videoHosts[participantID]; }
- (void)onRenderUserChanged:(ZoomSDKVideoElement *)element User:(unsigned int)userID {
    [self onMain:^{ [self logVideo:"render-user" element:element code:0]; [self refreshParticipants]; }];
}
- (void)onRenderDataTypeChanged:(ZoomSDKVideoElement *)element DataType:(VideoRenderDataType)type {
    [self onMain:^{ [self logVideo:"render-data" element:element code:type]; [self refreshParticipants]; }];
}
- (void)onSubscribeUserFail:(ZoomSDKVideoSubscribeFailReason)error videoElement:(ZoomSDKVideoElement *)element {
    [self onMain:^{
        if (!element || !self.sessionID || self.ending) return;
        NSString *identifier = [self.videos allKeysForObject:(id)element].firstObject;
        if (!identifier || ![self.subscribedVideos containsObject:identifier] || !self.videoHosts[identifier].isReadyForRenderer) return;
        [self logVideo:"subscription-failed" element:element code:error];
        if (error == ZoomSDKVideoSubscribe_Fail_TooFrequentCall) {
            [self scheduleVideoRetry:identifier element:(ZoomSDKNormalVideoElement *)element];
        } else if (error == ZoomSDKVideoSubscribe_Fail_HasSubscribeExceededLimit ||
            error == ZoomSDKVideoSubscribe_Fail_HasSubscribe1080POr720P ||
            error == ZoomSDKVideoSubscribe_Fail_HasSubscribe720P || error == ZoomSDKVideoSubscribe_Fail_HasSubscribeTwo720P) {
            [self emit:@"controlError" object:[NSString stringWithFormat:@"Zoom reached its incoming-video capacity (reason %ld). Reduce the gallery page size and try again.", (long)error]];
        } else if (error != ZoomSDKVideoSubscribe_Fail_None) {
            [self emit:@"controlError" object:[NSString stringWithFormat:@"Zoom could not receive a participant’s video (reason %ld).", (long)error]];
        }
    }];
}

- (BOOL)isWindowShareable:(uint32_t)windowID { return [[self.meeting getASController] isShareAppValid:windowID]; }
- (BOOL)isDesktopSharingEnabled { return [[self.meeting getASController] isDesktopSharingEnabled]; }
- (NSInteger)startSharingWindow:(uint32_t)windowID {
    ZoomSDKASController *share = [self.meeting getASController];
    if (!share || ![share isShareAppValid:windowID]) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = [share startAppShare:windowID];
    [self logConnection:"share-window-return" code:result status:[self.meeting getMeetingStatus] reason:0];
    if (result == ZoomSDKError_Success) [self confirmRequestedShareWindow:windowID display:0];
    return result;
}
- (NSInteger)startSharingDisplay:(uint32_t)displayID {
    ZoomSDKASController *share = [self.meeting getASController];
    if (!share || ![share isDesktopSharingEnabled]) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = [share startMonitorShare:displayID];
    [self logConnection:"share-display-return" code:result status:[self.meeting getMeetingStatus] reason:0];
    if (result == ZoomSDKError_Success) [self confirmRequestedShareWindow:0 display:displayID];
    return result;
}
- (NSInteger)stopSharing {
    // Cancel pending source-name reconciliation; the SDK's SelfEnd callback still
    // determines when the active-sharing controls disappear.
    self.shareSourceRevision += 1;
    ZoomSDKError result = self.meeting ? [[self.meeting getASController] stopShare] : ZoomSDKError_WrongUsage;
    [self logConnection:"share-stop-return" code:result status:[self.meeting getMeetingStatus] reason:0];
    return result;
}
- (void)publishLocalShareWindow:(uint32_t)windowID display:(uint32_t)displayID {
    if (!self.localShareActive) return;
    if (self.awaitingShareSource) {
        if (WHZoomShareSourceMatches(windowID, displayID, self.requestedShareWindowID, self.requestedShareDisplayID)) {
            self.awaitingShareSource = NO;
        } else {
            windowID = 0; displayID = 0;
        }
    }
    [self emit:@"sharing" object:@{@"active":@YES, @"windowID":@(windowID), @"displayID":@(displayID)}];
}
- (void)confirmRequestedShareWindow:(uint32_t)windowID display:(uint32_t)displayID {
    if (!self.sessionID || self.ending) return;
    self.requestedShareWindowID = windowID; self.requestedShareDisplayID = displayID;
    self.awaitingShareSource = YES;
    NSUInteger revision = ++self.shareSourceRevision;
    // Source switching can succeed without a status/content callback. Reconcile
    // from SDK source metadata, never from the success of the request alone.
    [self reconcileLocalShareSource:revision session:[self.sessionID copy] attempt:0];
}
- (void)reconcileLocalShareSource:(NSUInteger)revision session:(NSString *)session attempt:(NSUInteger)attempt {
    if (![self.sessionID isEqualToString:session] || self.ending ||
        self.shareSourceRevision != revision || !self.awaitingShareSource) return;
    unsigned int localID = [[[self.meeting getMeetingActionController] getMyself] getUserID];
    ZoomSDKASController *controller = [self.meeting getASController];
    if (localID != 0 && self.localShareActive) {
        for (ZoomSDKSharingSourceInfo *info in [controller getSharingSourceInfoList:localID] ?: @[]) {
            if (info.status == ZoomSDKShareStatus_None || info.status == ZoomSDKShareStatus_SelfEnd ||
                info.status == ZoomSDKShareStatus_OtherEnd || info.status == ZoomSDKShareStatus_Disconnected) continue;
            CGWindowID windowID = 0; CGDirectDisplayID displayID = 0;
            if ([info getWindowID:&windowID] != ZoomSDKError_Success) windowID = info.windowID;
            if ([info getDisplayID:&displayID] != ZoomSDKError_Success) displayID = info.displayID;
            if (WHZoomShareSourceMatches(windowID, displayID, self.requestedShareWindowID, self.requestedShareDisplayID)) {
                [self publishLocalShareWindow:windowID display:displayID];
                os_log_info(WHZoomConnectionLog(), "share=source-confirmed attempt=%{public}lu windowPresent=%{public}d displayPresent=%{public}d",
                    (unsigned long)attempt, windowID != 0, displayID != 0);
                return;
            }
        }
    }
    if (attempt == 0) [self publishLocalShareWindow:0 display:0];
    if (attempt >= 8) {
        os_log_info(WHZoomConnectionLog(), "share=source-unconfirmed active=%{public}d", self.localShareActive);
        return; // Keep truthful generic source wording and the confirmed Stop control.
    }
    __weak typeof(self) weakSelf = self;
    NSTimeInterval delay = MIN(1.0, 0.1 * (1 << attempt));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf reconcileLocalShareSource:revision session:session attempt:attempt + 1];
    });
}
- (void)onSharingStatusChanged:(ZoomSDKSharingSourceInfo *)info {
    ZoomSDKShareStatus status = info.status; unsigned int ownerID = info.userID;
    CGWindowID windowID = 0; CGDirectDisplayID displayID = 0;
    if ([info getWindowID:&windowID] != ZoomSDKError_Success) windowID = info.windowID;
    if ([info getDisplayID:&displayID] != ZoomSDKError_Success) displayID = info.displayID;
    [self onMain:^{ [self sharingStatus:status owner:ownerID window:windowID display:displayID]; }];
}
- (void)sharingStatus:(ZoomSDKShareStatus)status owner:(unsigned int)ownerID window:(uint32_t)windowID display:(uint32_t)displayID {
    if (!self.sessionID) return;
    unsigned int localID = [[[self.meeting getMeetingActionController] getMyself] getUserID];
    WHZoomLocalShareUpdate update = WHZoomLocalShareUpdateForStatus(status, ownerID, localID);
    // No window/display/user identifiers or titles enter diagnostics.
    os_log_info(WHZoomConnectionLog(), "share=status status=%{public}ld update=%{public}lu ownerPresent=%{public}d localOwner=%{public}d windowPresent=%{public}d displayPresent=%{public}d",
        (long)status, (unsigned long)update, ownerID != 0, ownerID != 0 && ownerID == localID, windowID != 0, displayID != 0);
    switch (update) {
        case WHZoomLocalShareUpdateActive:
            self.localShareActive = YES;
            [self publishLocalShareWindow:windowID display:displayID];
            break;
        case WHZoomLocalShareUpdateIdle:
            self.localShareActive = NO; self.awaitingShareSource = NO; self.shareSourceRevision += 1;
            [self emit:@"sharing" object:@{@"active":@NO}];
            break;
        case WHZoomLocalShareUpdateUnchanged: break;
    }
    [self refreshShares];
}
- (void)onShareContentChanged:(ZoomSDKSharingSourceInfo *)info { [self onSharingStatusChanged:info]; }
- (void)onFailedToStartShare { [self emit:@"controlError" object:@"Zoom could not start sharing. Check screen recording permission and the meeting’s sharing settings."]; }
- (void)refreshShares {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshShares]; }); return; }
    ZoomSDKASController *controller = [self.meeting getASController];
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    unsigned int localID = [[action getMyself] getUserID];
    NSMutableArray *sources = [NSMutableArray array];
    for (NSNumber *owner in [controller getViewableSharingUserList] ?: @[]) {
        if (owner.unsignedIntValue == localID) continue;
        for (ZoomSDKSharingSourceInfo *info in [controller getSharingSourceInfoList:owner.unsignedIntValue] ?: @[]) {
            if (info.status == ZoomSDKShareStatus_OtherEnd || info.status == ZoomSDKShareStatus_None) continue;
            [sources addObject:@{@"id":@(info.shareSourceID).stringValue, @"ownerID":@(info.userID).stringValue,
                @"ownerName":[[action getUserByUserID:info.userID] getUserName] ?: @"Participant", @"title":@"Shared screen"}];
        }
    }
    [self emit:@"receivedShares" object:sources];
}
- (void)selectReceivedShare:(NSString *)sourceID {
    if ((sourceID == nil && self.selectedShareID == nil) || [sourceID isEqualToString:self.selectedShareID]) return;
    ZoomSDKShareContainer *container = [[self.meeting getASController] getShareContainer];
    self.shareHost.resizeRenderer = nil;
    if (self.shareElement) {
        [self.shareElement ShowShareRender:NO]; [self.shareElement.shareView removeFromSuperview];
        [container cleanShareElement:self.shareElement];
    }
    self.shareElement = nil; self.shareHost = nil; self.selectedShareID = nil;
    if (!sourceID || !container || self.ending) return;
    ZoomSDKShareElement *element = [[ZoomSDKShareElement alloc] initWithFrame:NSMakeRect(0, 0, 960, 540)];
    if ([container createShareElement:&element] != ZoomSDKError_Success || !element) return;
    element.sharingID = sourceID.intValue; element.viewMode = ViewShareMode_LetterBox;
    WHZoomRenderHost *host = [[WHZoomRenderHost alloc] initWithFrame:NSMakeRect(0, 0, 960, 540)];
    if (element.shareView) [host addSubview:element.shareView];
    __weak ZoomSDKShareElement *weakElement = element;
    host.resizeRenderer = ^(NSRect bounds) { [weakElement resize:bounds]; };
    self.shareElement = element; self.shareHost = host; self.selectedShareID = sourceID;
    [element resize:host.bounds]; [element ShowShareRender:YES];
}
- (NSView *)shareViewForSource:(NSString *)sourceID { return [sourceID isEqualToString:self.selectedShareID] ? self.shareHost : nil; }

- (void)refreshIndicators {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshIndicators]; }); return; }
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *identifier in [self.indicators.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [items addObject:@{@"id":identifier, @"title":self.indicators[identifier].indicatorName ?: @"Meeting privacy"}];
    }
    if ([self.appSignal canShowPanel]) [items addObject:@{@"id":@"yap.zoom.app-signal", @"title":@"Apps and privacy"}];
    [self emit:@"indicators" object:items];
}
- (void)onIndicatorItemReceived:(ZoomSDKMeetingIndicatorHandle *)handler {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onIndicatorItemReceived:handler]; }); return; }
    if (handler.indicatorItemId.length) self.indicators[handler.indicatorItemId] = handler;
    [self refreshIndicators]; [self refreshChatNotice];
}
- (void)onIndicatorItemRemoved:(ZoomSDKMeetingIndicatorHandle *)handler {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onIndicatorItemRemoved:handler]; }); return; }
    if (handler.indicatorItemId) [self.indicators removeObjectForKey:handler.indicatorItemId];
    [self refreshIndicators]; [self refreshChatNotice];
}
- (void)onAppSignalPanelUpdated:(ZoomSDKMeetingAppsignalHandler *)handler { [self onMain:^{ self.appSignal = handler; [self refreshIndicators]; }]; }
- (NSInteger)showMeetingIndicator:(NSString *)indicatorID {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window) return ZoomSDKError_WrongUsage;
    NSPoint point = NSMakePoint(NSMidX(window.frame), NSMaxY(window.frame) - 70);
    if ([indicatorID isEqualToString:@"yap.zoom.app-signal"] && self.appSignal) return [self.appSignal showPanel:point parentWindow:window];
    ZoomSDKMeetingIndicatorHandle *handler = self.indicators[indicatorID];
    return handler ? [handler showIndicatorPanel:point parentWindow:window] : ZoomSDKError_WrongUsage;
}

- (void)presentAlert:(NSAlert *)alert completion:(void (^)(NSModalResponse))completion {
    if (!self.sessionID || self.ending) return;
    NSString *session = [self.sessionID copy];
    [self.alerts addObject:alert];
    [self cancelConnectionWatchdog];
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    void (^finished)(NSModalResponse) = ^(NSModalResponse response) {
        [self.alerts removeObject:alert];
        if ([self.sessionID isEqualToString:session] && !self.ending) {
            completion(response);
            if ([self.sessionID isEqualToString:session] && !self.ending) [self updateConnectionWatchdogForStatus:[self.meeting getMeetingStatus]];
        }
    };
    if (window) [alert beginSheetModalForWindow:window completionHandler:finished];
    else finished([alert runModal]);
}
- (void)onReminderNotify:(ZoomSDKReminderHandler *)handler reminderContent:(ZoomSDKReminderContent *)content {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onReminderNotify:handler reminderContent:content]; }); return; }
    NSAlert *alert = [NSAlert new]; alert.messageText = content.title ?: @"Zoom meeting notice";
    alert.informativeText = content.content ?: @"";
    if (content.actionType != ZoomSDKReminderActionType_None) {
        [alert addButtonWithTitle:@"Leave meeting"];
        [self presentAlert:alert completion:^(NSModalResponse response) { [handler decline]; [self leaveEndingMeeting:NO]; }];
        return;
    }
    [alert addButtonWithTitle:@"Continue"]; [alert addButtonWithTitle:@"Leave meeting"];
    [self presentAlert:alert completion:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [handler accept];
        else { [handler decline]; [self leaveEndingMeeting:NO]; }
    }];
}
- (void)onEnableReminderNotify:(ZoomSDKMeetingEnableReminderHandler *)handler reminderContent:(ZoomSDKReminderContent *)content {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onEnableReminderNotify:handler reminderContent:content]; }); return; }
    // This handler starts smart/AI features, not ordinary cloud recording.
    // Ordinary recording consent remains in onReminderNotify above.
    NSAlert *alert = [NSAlert new]; alert.messageText = content.title ?: @"Zoom meeting feature";
    alert.informativeText = content.content ?: @""; [alert addButtonWithTitle:@"Keep disabled"];
    [self presentAlert:alert completion:^(NSModalResponse response) { [handler decline:NO]; }];
}
- (void)onJoinMeetingResponse:(ZoomSDKJoinMeetingHelper *)helper {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onJoinMeetingResponse:helper]; }); return; }
    if (!helper) return;
    JoinMeetingReqInfoType type = [helper getReqInfoType];
    if (type != JoinMeetingReqInfoType_Password && type != JoinMeetingReqInfoType_Password_Wrong && type != JoinMeetingReqInfoType_ScreenName) {
        [helper cancel]; return;
    }
    NSAlert *alert = [NSAlert new];
    BOOL password = type != JoinMeetingReqInfoType_ScreenName;
    alert.messageText = password ? @"Meeting passcode" : @"Your name";
    alert.informativeText = type == JoinMeetingReqInfoType_Password_Wrong ? @"Zoom did not accept the passcode. Enter the passcode from your invitation." : @"Enter the information required to join this meeting.";
    NSTextField *field = password ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0,0,300,24)] : [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,300,24)];
    alert.accessoryView = field; [alert addButtonWithTitle:@"Join"]; [alert addButtonWithTitle:@"Cancel"];
    [self presentAlert:alert completion:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) [helper cancel];
        else if (password) [helper inputPassword:field.stringValue];
        else [helper inputMeetingScreenName:field.stringValue];
        field.stringValue = @"";
    }];
}
- (void)onUserConfirmToStartArchive:(ZoomSDKMeetingArchiveConfirmHandler *)handler {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onUserConfirmToStartArchive:handler]; }); return; }
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Meeting archiving";
    alert.informativeText = handler.archiveConfirmContent ?: @"This meeting requires an archiving choice.";
    [alert addButtonWithTitle:@"Join with archiving"]; [alert addButtonWithTitle:@"Leave meeting"];
    [self presentAlert:alert completion:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [handler joinWithArchive:YES];
        else [self leaveEndingMeeting:NO];
    }];
}
- (void)onEndOtherMeetingToJoinMeetingNotification:(ZoomSDKError (^)(void))endOther actionCancel:(void (^)(void))cancel {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onEndOtherMeetingToJoinMeetingNotification:endOther actionCancel:cancel]; }); return; }
    // Starting Yap is not authorization to end a separate meeting.
    cancel(); [self emit:@"controlError" object:@"Another meeting is already running. Leave that meeting before joining here."];
}
- (void)onJoinMeetingNeedUserInfo:(ZoomSDKMeetingInputUserInfoHandler *)handler {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self onJoinMeetingNeedUserInfo:handler]; }); return; }
    [handler cancel];
    [self emit:@"controlError" object:@"This meeting requires registration details. Complete its registration before joining."];
}

// The SDK marks these feature callbacks as required even when the app does not expose that feature.
- (void)onUserInfoUpdate:(unsigned int)userID { [self refreshParticipants]; }
- (void)onVirtualNameTagStatusChanged:(BOOL)bOn userID:(unsigned int)userID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onVirtualNameTagRosterInfoUpdated:(unsigned int)userID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onSpotlightVideoUserChange:(NSArray*_Nullable)spotlightedUserList { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onLowOrRaiseHandStatusChange:(BOOL)raise UserID:(unsigned int)userID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onMultiToSingleShareNeedConfirm:(ZoomSDKMultiToSingleShareConfirmHandler*_Nullable)confirmHandle { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onActiveVideoUserChanged:(unsigned int)userID { [self refreshParticipants]; }
- (void)onActiveSpeakerVideoUserChanged:(unsigned int)userID { [self refreshParticipants]; }
- (void)onHostAskUnmute { [self emit:@"controlError" object:@"The host asked you to unmute. Use the microphone control when you’re ready."]; }
- (void)onHostAskStartVideo { [self emit:@"controlError" object:@"The host asked you to start video. Use the camera control when you’re ready."]; }
- (void)onInvalidReclaimHostKey { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onHostVideoOrderUpdated:(NSArray*)orderList { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onLocalVideoOrderUpdated:(NSArray*)localOrderList { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onFollowHostVideoOrderChanged:(BOOL)follow { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onAllHandsLowered { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onUserVideoQualityChanged:(ZoomSDKVideoQuality)quality userID:(unsigned int)userID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onChatMsgDeleteNotification:(NSString*)msgID messageDeleteType:(ZoomSDKChatMessageDeleteType)deleteBy { [self emit:@"chatDeleted" object:[msgID copy] ?: @""]; }
- (void)onShareMeetingChatStatusChanged:(BOOL)isStart { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onSuspendParticipantsActivities { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onAllowParticipantsStartVideoNotification:(BOOL)allow { [self refreshParticipants]; }
- (void)onAllowParticipantsRenameNotification:(BOOL)allow { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onAllowParticipantsUnmuteSelfNotification:(BOOL)allow { [self refreshParticipants]; }
- (void)onAllowParticipantsShareWhiteBoardNotification:(BOOL)allow { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onMeetingLockStatus:(BOOL)isLock { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onRequestLocalRecordingPrivilegeChanged:(ZoomSDKLocalRecordingRequestPrivilegeStatus)status { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onAllowParticipantsRequestCloudRecording:(BOOL)allow { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onInMeetingUserAvatarPathUpdated:(unsigned int)userID {
    [self onMain:^{
        if (!self.sessionID || self.ending) return;
        NSNumber *identifier = @(userID);
        self.avatarRevisions[identifier] = @(self.avatarRevisions[identifier].integerValue + 1);
        [self logConnection:"avatar-updated" code:0 status:0 reason:0];
        [self refreshParticipants];
    }];
}
- (void)onAICompanionActiveChangeNotice:(BOOL)active { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onParticipantProfilePictureStatusChange:(BOOL)hidden {
    [self onMain:^{
        if (!self.sessionID || self.ending) return;
        if (!hidden && self.profilePicturesHidden.boolValue) [self.requestedAvatars removeAllObjects];
        self.profilePicturesHidden = @(hidden);
        [self refreshParticipants];
    }];
}
- (void)onVideoAlphaChannelStatusChanged:(BOOL)isAlphaModeOn { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onFocusModeStateChanged:(BOOL)on { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onFocusModeShareTypeChanged:(ZoomSDKFocusModeShareType)shareType { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onMeetingQAStatusChanged:(BOOL)isMeetingQAFeatureOn { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)notifyToJoin3rdPartyTelephonyAudio:(NSString*)audioInfo { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onCameraControlRequestReceived:(unsigned int)userId requestType:(ZoomSDKCameraControlRequestType)requestType actionApprove:(nullable ZoomSDKError(^)(void))actionApprove actionDecline:(nullable ZoomSDKError(^)(void))actionDecline { [self onMain:^{ if (actionDecline) actionDecline(); }]; }
- (void)onCameraControlRequestResult:(unsigned int)userId resultType:(ZoomSDKCameraControlRequestResult)resultType { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onMuteOnEntryStatusChange:(BOOL)enable { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onMeetingTopicChanged:(NSString *)topic { [self refreshParticipants]; }
- (void)onBotAuthorizerRelationChanged:(unsigned int)authorizeUserID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onCreateCompanionRelation:(unsigned int)parentUserID childUserID:(unsigned int)childUserID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onRemoveCompanionRelation:(unsigned int)childUserID { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onGrantCoOwnerPrivilegeChanged:(BOOL)canGrantOther { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onChatMessageEditNotification:(ZoomSDKChatInfo*)chatInfo { [self publishChat:chatInfo event:@"chatEdited"]; }
- (void)onFileSendStart:(ZoomSDKFileSender *)sender { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onFileReceived:(ZoomSDKFileReceiver *)receiver { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onFileTransferProgress:(ZoomSDKFileTransferInfo *)info { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onWaitingRoomPresetAudioStatusChanged:(BOOL)audioCanTurnOn { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onWaitingRoomPresetVideoStatusChanged:(BOOL)videoCanTurnOn { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onCustomWaitingRoomDataUpdated:(ZoomSDKCustomWaitingRoomData*_Nullable)bData handle:(ZoomSDKWaitingRoomDataDownloadHandler*_Nullable)handle { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onWaitingRoomEntranceEnabled:(BOOL)enabled { [self refreshWaitingRoom]; }
- (void)onRecord2MP4Done:(BOOL)success Path:(NSString*)recordPath { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onRecord2MP4Progressing:(int)percentage { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onRecordPrivilegeChange:(BOOL)canRec { [self refreshCloudRecording]; }
- (void)onCustomizedRecordingSourceReceived:(CustomizedRecordingLayoutHelper*)helper { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onLocalRecordingPrivilegeRequestStatus:(ZoomSDKRequestLocalRecordingStatus)status { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onLocalRecordingPrivilegeRequested:(ZoomSDKRequestLocalRecordingPrivilegeHandler *_Nullable)handler { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onCloudRecordingStorageFull:(time_t)gracePeriodDate {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!session || ![self.sessionID isEqualToString:session] || self.ending) return;
        [self refreshCloudRecording];
        // This callback can include an account grace period; it does not prove
        // the current recording stopped. Keep the actual SDK status visible.
        [self emit:@"cloudRecordingError" object:@"Zoom reports that cloud recording storage is full. Check the recording status and manage the host’s cloud storage in Zoom."];
    }];
}
- (void)onRequestCloudRecordingResponse:(ZoomSDKRequestStartCloudRecordingStatus)status { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onStartCloudRecordingRequested:(ZoomSDKRequestStartCloudRecordingHandler *_Nullable)handler {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!handler || !session || ![self.sessionID isEqualToString:session] || self.ending) return;
        if ([self consumeCloudRecordingStartRequestFrom:handler.requesterId]) [self finishCloudRecordingRequestWithResult:[handler start]];
        else [handler deny:NO];
    }];
}
- (void)onEnableAndStartSmartRecordingRequested:(ZoomSDKRequestEnableAndStartSmartRecordingHandler *_Nullable)handler {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!handler || !session || ![self.sessionID isEqualToString:session] || self.ending) return;
        if ([self consumeCloudRecordingStartRequestFrom:handler.requestUserID]) {
            // Complete only our explicit start, without enabling smart recording
            // for this meeting or changing any future-meeting account setting.
            [self finishCloudRecordingRequestWithResult:[handler startCloudRecordingWithoutEnableSmartRecording]];
        } else [handler deny:NO];
    }];
}
- (void)onSmartRecordingEnableActionCallback:(ZoomSDKSmartRecordingEnableActionHandler *_Nullable)handler {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!handler || !session || ![self.sessionID isEqualToString:session] || self.ending) return;
        [handler actionCancel];
    }];
}
@end
