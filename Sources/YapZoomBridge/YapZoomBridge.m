#import "YapZoomBridge.h"
#import <ZoomSDK/ZoomSDK.h>
#import <os/log.h>
#import <math.h>
#import "WHZoomRenderHost.h"
#import "WHZoomVideoDetachGrace.h"
#import "WHZoomCloudRecordingPolicy.h"
#import "WHZoomShareStatus.h"
#import "WHPhotoShutterAudio.h"
#import "WHZoomChatSupport.h"
#import <AVFoundation/AVFoundation.h>

// Zoom owns one SDK per process, including pre-meeting camera settings.
static __weak WHZoomSDKBridge *WHZoomNativeOwner;

// A fresh observer per authorization/test lets queued SDK callbacks retain
// their original generation instead of acting on a later meeting or test.
@interface WHZoomMediaObserver : NSObject <ZoomSDKSettingAudioDeviceDelegate, ZoomSDKSettingTestAudioDelegate>
@property(nonatomic, copy) void (^deviceChanged)(BOOL microphone, ZoomSDKDeviceStatus status, BOOL selectionChanged);
@property(nonatomic, copy) void (^microphoneChanged)(ZoomSDKTestMicStatus status, BOOL afterStart);
@property(nonatomic, copy) void (^speakerChanged)(BOOL running, BOOL afterStart);
@property(atomic) BOOL testStartConfirmed;
@end
@implementation WHZoomMediaObserver
- (void)onMicDeviceStatusChanged:(ZoomSDKDeviceStatus)status { if (self.deviceChanged) self.deviceChanged(YES, status, NO); }
- (void)onSpeakerDeviceStatusChanged:(ZoomSDKDeviceStatus)status { if (self.deviceChanged) self.deviceChanged(NO, status, NO); }
- (void)onSelectedMicDeviceChanged { if (self.deviceChanged) self.deviceChanged(YES, Device_List_Update, YES); }
- (void)onSelectedSpeakerDeviceChanged { if (self.deviceChanged) self.deviceChanged(NO, Device_List_Update, YES); }
- (void)onMicTestStatusChanged:(ZoomSDKTestMicStatus)status { if (self.microphoneChanged) self.microphoneChanged(status, self.testStartConfirmed); }
- (void)onSpeakerTestStatusChanged:(BOOL)running { if (self.speakerChanged) self.speakerChanged(running, self.testStartConfirmed); }
@end

static BOOL WHZoomStatusIsTerminal(ZoomSDKMeetingStatus status) {
    return status == ZoomSDKMeetingStatus_Idle || status == ZoomSDKMeetingStatus_Ended || status == ZoomSDKMeetingStatus_Failed;
}

static os_log_t WHZoomConnectionLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("app.yap.zoom", "connection"); });
    return log;
}

static void WHZoomLogMediaTest(BOOL microphone, NSInteger phase, NSInteger status, NSInteger result) {
    // Numeric lifecycle diagnostics contain no device identifiers or names.
    os_log_info(WHZoomConnectionLog(), "media-test kind=%{public}d phase=%{public}ld status=%{public}ld result=%{public}ld",
                microphone ? 0 : 1, (long)phase, (long)status, (long)result);
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
    ZoomSDKMeetingRecordDelegate, ZoomSDKDirectShareHelperDelegate,
    ZoomSDKVirtualBackgroundSettingDelegate, ZoomSDKSettingVideoDelegate>
@property(nonatomic) BOOL cameraSettingsOnly;
@property(nonatomic) BOOL cameraEffectsReady;
@property(nonatomic, copy) NSString *cameraEffectsError;
@property(nonatomic) BOOL cameraEffectsAwaitingConfirmation;
@property(nonatomic, copy) void (^cameraPreparationCompletion)(NSInteger, NSString *);
@property(nonatomic, strong) NSUUID *cameraPreparationToken;
@property(nonatomic, copy) NSString *preferredCameraBackground;
@property(nonatomic, copy) NSString *preferredCameraImagePath;
@property(nonatomic) BOOL preferredCameraAutoFraming;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cameraImageAliases;
@property(nonatomic, copy) NSString *confirmedCameraImagePath;
@property(nonatomic, strong) ZoomSDKSettingTestVideoDeviceHelper *cameraPreviewHelper;
@property(nonatomic, strong) WHZoomRenderHost *cameraPreviewHost;
@property(nonatomic) BOOL cameraPreviewStarted;
@property(nonatomic) BOOL cameraPreviewStartScheduled;
@property(nonatomic) BOOL cameraPreviewBound;
@property(nonatomic) NSUInteger cameraPreviewRevision;
@property(nonatomic, copy) NSString *cameraPreviewError;
@property(nonatomic, strong) NSUUID *mediaGeneration;
@property(nonatomic, strong) WHZoomMediaObserver *mediaDeviceObserver;
@property(nonatomic, strong) WHZoomMediaObserver *mediaMicrophoneObserver;
@property(nonatomic, strong) WHZoomMediaObserver *mediaSpeakerObserver;
@property(nonatomic, strong) ZoomSDKSettingTestMicrophoneDeviceHelper *mediaMicrophoneHelper;
@property(nonatomic, strong) ZoomSDKSettingTestSpeakerDeviceHelper *mediaSpeakerHelper;
@property(nonatomic, strong) NSUUID *mediaMicrophoneTestToken;
@property(nonatomic, strong) NSUUID *mediaSpeakerTestToken;
@property(nonatomic, copy) NSString *mediaMicrophoneTestState;
@property(nonatomic, copy) NSString *mediaMicrophoneTestDeviceID;
@property(nonatomic, copy) NSString *mediaSpeakerTestDeviceID;
@property(nonatomic, copy) NSString *mediaDevicesError;
@property(nonatomic) BOOL mediaMicrophoneStopFailed;
@property(nonatomic) BOOL mediaSpeakerStopFailed;
@property(nonatomic) BOOL mediaMicrophoneNeedsRecordingStop;
@property(nonatomic, strong) WHPhotoShutterAudio *photoShutter;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZoomSDKFileSender *> *chatFileSenders;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZoomSDKFileReceiver *> *chatFileReceivers;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *chatFileMetadata;
@property(nonatomic, copy) NSDictionary *lastChatPolicy;
@property(nonatomic) BOOL roomShare;
@property(nonatomic) BOOL directShareRunning;
@property(nonatomic, strong) ZoomSDKDirectShareHelper *directShareHelper;
@property(nonatomic, strong) ZoomSDKDirectShareHandler *directShareCodeHandler;
@property(nonatomic, strong) ZoomSDKDirectShareSpecifyContentHandler *directShareContentHandler;
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
@property(nonatomic) BOOL sharingComputerAudio;
@property(nonatomic) BOOL requestedComputerAudio;
@property(nonatomic) BOOL awaitingShareSource;
@property(nonatomic) NSUInteger shareSourceRevision;
@property(nonatomic) uint32_t requestedShareWindowID;
@property(nonatomic) uint32_t requestedShareDisplayID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZoomSDKNormalVideoElement *> *videos;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WHZoomRenderHost *> *videoHosts;
@property(nonatomic, strong) NSMutableSet<NSString *> *subscribedVideos;
@property(nonatomic, strong) NSMutableSet<NSString *> *videosReportingLiveData;
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
        _videosReportingLiveData = [NSMutableSet set];
        _requestedAvatars = [NSMutableSet set]; _avatarRevisions = [NSMutableDictionary dictionary];
        _participantVideoSizes = [NSMutableDictionary dictionary];
        _videoDetachGrace = [WHZoomVideoDetachGrace new];
        _videoRetryAttempts = [NSMutableDictionary dictionary];
        _videoRetryTokens = [NSMutableDictionary dictionary]; _videoRetryExhausted = [NSMutableSet set];
        _indicators = [NSMutableDictionary dictionary]; _alerts = [NSMutableArray array];
        _preferredCameraBackground = @"none";
        _cameraImageAliases = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setPreferredCameraBackground:(NSString *)background imagePath:(NSString *)path autoFraming:(BOOL)autoFraming {
    self.preferredCameraBackground = background;
    self.preferredCameraImagePath = path;
    self.preferredCameraAutoFraming = autoFraming;
}

- (BOOL)mediaControlsReady {
    return WHZoomNativeOwner == self && self.initialized && self.cameraEffectsReady && self.mediaGeneration && !self.ending;
}

- (NSArray *)mediaDeviceItems:(NSArray *)devices {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (SDKDeviceInfo *device in devices) {
        NSString *identifier = [device getDeviceID];
        if (!identifier.length || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        [items addObject:@{@"id":identifier, @"name":[device getDeviceName] ?: @"Device", @"selected":[NSNumber numberWithBool:[device isSelectedDevice]]}];
    }
    return items;
}

- (SDKDeviceInfo *)selectedMediaDevice:(NSArray *)devices {
    for (SDKDeviceInfo *device in devices) if ([device isSelectedDevice] && [device getDeviceID].length) return device;
    return nil;
}

- (NSData *)meetingMediaSnapshot {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    BOOL ready = [self mediaControlsReady];
    ZoomSDKSettingService *settings = ready ? [[ZoomSDK sharedSDK] getSettingService] : nil;
    ZoomSDKAudioSetting *audio = [settings getAudioSetting];
    NSArray *microphones = [audio getAudioDeviceList:YES];
    NSArray *speakers = [audio getAudioDeviceList:NO];
    BOOL hasMic = [self selectedMediaDevice:microphones] != nil;
    BOOL hasSpeaker = [self selectedMediaDevice:speakers] != nil;
    BOOL automatic = audio && [audio isAutoAdjustMicOn];
    float micVolume = hasMic ? [audio getAudioDeviceVolume:YES] : NAN;
    float speakerVolume = hasSpeaker ? [audio getAudioDeviceVolume:NO] : NAN;
    NSDictionary *snapshot = @{
        @"isReady":[NSNumber numberWithBool:ready], @"isInMeeting":[NSNumber numberWithBool:ready && self.sessionID && self.hasEnteredMeeting],
        @"microphones":[self mediaDeviceItems:microphones], @"speakers":[self mediaDeviceItems:speakers],
        @"cameras":[self mediaDeviceItems:[[settings getVideoSetting] getCameraList]],
        @"microphoneVolume":isfinite(micVolume) && micVolume >= 0 && micVolume <= 100 ? @(lroundf(micVolume)) : NSNull.null,
        @"speakerVolume":isfinite(speakerVolume) && speakerVolume >= 0 && speakerVolume <= 100 ? @(lroundf(speakerVolume)) : NSNull.null,
        @"error":self.mediaDevicesError ?: NSNull.null,
        @"automaticMicrophoneVolume":[NSNumber numberWithBool:automatic],
        @"canSetMicrophoneVolume":[NSNumber numberWithBool:hasMic && !automatic], @"canSetSpeakerVolume":[NSNumber numberWithBool:hasSpeaker],
        @"microphoneTest":ready && self.mediaMicrophoneTestToken ? (self.mediaMicrophoneTestState ?: @"idle") : @"idle",
        @"speakerTestRunning":[NSNumber numberWithBool:ready && self.mediaSpeakerTestToken != nil]
    };
    return [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
}

- (void)emitMediaDevices {
    NSData *data = [self meetingMediaSnapshot];
    if (self.mediaDevicesChanged) self.mediaDevicesChanged(data);
    if (self.sessionID && WHZoomNativeOwner == self && self.eventHandler)
        self.eventHandler(self.sessionID, @"mediaDevices", data);
}

- (NSInteger)stopMediaTestKind:(NSString *)kind {
    BOOL microphone = [kind isEqualToString:@"microphone"];
    ZoomSDKSettingTestMicrophoneDeviceHelper *mic = microphone ? self.mediaMicrophoneHelper : nil;
    ZoomSDKSettingTestSpeakerDeviceHelper *speaker = microphone ? nil : self.mediaSpeakerHelper;
    BOOL wasRecording = microphone && self.mediaMicrophoneNeedsRecordingStop;
    NSString *testDeviceID = microphone ? self.mediaMicrophoneTestDeviceID : self.mediaSpeakerTestDeviceID;
    NSUUID *generation = self.mediaGeneration;
    if (microphone) {
        self.mediaMicrophoneTestToken = nil; self.mediaMicrophoneTestState = @"idle";
        self.mediaMicrophoneTestDeviceID = nil;
        self.mediaMicrophoneStopFailed = NO; self.mediaMicrophoneNeedsRecordingStop = NO;
        mic.delegate = nil;
        self.mediaMicrophoneHelper = nil; self.mediaMicrophoneObserver = nil;
    } else {
        self.mediaSpeakerTestToken = nil;
        self.mediaSpeakerTestDeviceID = nil;
        speaker.delegate = nil;
        self.mediaSpeakerHelper = nil; self.mediaSpeakerObserver = nil;
        self.mediaSpeakerStopFailed = NO;
    }
    if (!mic && !speaker) return ZoomSDKError_Success;
    if (WHZoomNativeOwner != self) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = ZoomSDKError_Success;
    BOOL recordingStopFailed = NO;
    if (mic) {
        if (wasRecording || [mic getTestMicStatus] == testMic_Recording) result = [mic stopRecrodingMic];
        recordingStopFailed = result != ZoomSDKError_Success;
        ZoomSDKError stopped = [mic stopPlayRecordedMic];
        if (result == ZoomSDKError_Success) result = stopped;
    }
    if (speaker) result = [speaker SpeakerStopPlaying];
    WHZoomLogMediaTest(microphone, 7, mic ? [mic getTestMicStatus] : speaker.isSpeakerInTesting, result);
    if (result != ZoomSDKError_Success && WHZoomNativeOwner == self && self.mediaGeneration == generation) {
        // Failed stop is still an owned, active test. Keep a retryable handle,
        // but never restore the observer/token from the cancelled operation.
        if (mic && !self.mediaMicrophoneHelper && !self.mediaMicrophoneTestToken) {
            self.mediaMicrophoneHelper = mic; self.mediaMicrophoneTestToken = [NSUUID UUID];
            self.mediaMicrophoneTestDeviceID = testDeviceID;
            self.mediaMicrophoneTestState = @"stoppingFailed"; self.mediaMicrophoneStopFailed = YES;
            self.mediaMicrophoneNeedsRecordingStop = recordingStopFailed;
        }
        if (speaker && !self.mediaSpeakerHelper && !self.mediaSpeakerTestToken) {
            self.mediaSpeakerHelper = speaker; self.mediaSpeakerTestToken = [NSUUID UUID]; self.mediaSpeakerStopFailed = YES;
            self.mediaSpeakerTestDeviceID = testDeviceID;
        }
        self.mediaDevicesError = @"Zoom hasn’t confirmed that the audio test stopped. Try Stop again before changing devices or starting another test.";
    }
    return result;
}

- (NSInteger)stopMediaTestsForTransition {
    NSInteger microphone = [self stopMediaTestKind:@"microphone"];
    NSInteger speaker = [self stopMediaTestKind:@"speaker"];
    return microphone != ZoomSDKError_Success ? microphone : speaker;
}

- (void)stopMediaTests {
    NSInteger result = [self stopMediaTestsForTransition];
    if (result == ZoomSDKError_Success) self.mediaDevicesError = nil;
    [self emitMediaDevices];
}

- (NSInteger)mediaControlResult:(NSInteger)result message:(NSString *)message {
    self.mediaDevicesError = result == ZoomSDKError_Success ? nil : message;
    [self emitMediaDevices]; return result;
}

- (void)installMediaDeviceObserver {
    self.mediaGeneration = [NSUUID UUID];
    NSUUID *generation = self.mediaGeneration;
    __weak typeof(self) weakSelf = self;
    WHZoomMediaObserver *observer = [WHZoomMediaObserver new];
    observer.deviceChanged = ^(BOOL microphone, ZoomSDKDeviceStatus status, BOOL selectionChanged) {
        [weakSelf onMain:^{
            typeof(self) self = weakSelf;
            if (![self mediaControlsReady] || self.mediaGeneration != generation) return;
            NSString *testDevice = microphone ? self.mediaMicrophoneTestDeviceID : self.mediaSpeakerTestDeviceID;
            ZoomSDKAudioSetting *audio = [[[ZoomSDK sharedSDK] getSettingService] getAudioSetting];
            NSString *selected = [[self selectedMediaDevice:[audio getAudioDeviceList:microphone]] getDeviceID];
            BOOL failed = status == Device_Error_Unknown || status == Device_Error_Found || status == No_Device;
            BOOL changed = testDevice.length && ![testDevice isEqualToString:selected];
            BOOL shouldStop = testDevice.length && (failed || changed);
            WHZoomLogMediaTest(microphone, selectionChanged ? 10 : 9, status, shouldStop);
            // Muted/no-input notifications describe audio state, not device
            // removal. A list refresh also need not change the active device.
            if (shouldStop) [self stopMediaTestKind:microphone ? @"microphone" : @"speaker"];
            [self emitMediaDevices];
        }];
    };
    self.mediaDeviceObserver = observer;
    [[[[ZoomSDK sharedSDK] getSettingService] getAudioSetting] setDelegate:observer];
    [self emitMediaDevices];
}

- (NSInteger)selectMediaDevice:(NSString *)deviceID kind:(NSString *)kind {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    self.mediaDevicesError = nil;
    if (![self mediaControlsReady]) return ZoomSDKError_WrongUsage;
    BOOL camera = [kind isEqualToString:@"camera"], microphone = [kind isEqualToString:@"microphone"];
    if (!camera && !microphone && ![kind isEqualToString:@"speaker"]) return ZoomSDKError_InvalidParameter;
    if (self.mediaMicrophoneStopFailed || self.mediaSpeakerStopFailed) {
        NSInteger stopped = [self stopMediaTestsForTransition];
        if (stopped != ZoomSDKError_Success) return [self mediaControlResult:stopped message:@"Stop the audio test before changing devices. Zoom hasn’t confirmed that it stopped yet."];
    }
    ZoomSDKSettingService *settings = [[ZoomSDK sharedSDK] getSettingService];
    ZoomSDKAudioSetting *audio = [settings getAudioSetting];
    ZoomSDKVideoSetting *video = [settings getVideoSetting];
    NSArray *devices = camera ? [video getCameraList] : [audio getAudioDeviceList:microphone];
    SDKDeviceInfo *selected = nil;
    for (SDKDeviceInfo *device in devices) if (deviceID.length && [[device getDeviceID] isEqualToString:deviceID]) { selected = device; break; }
    if (!selected) return ZoomSDKError_InvalidParameter;
    if ([selected isSelectedDevice]) return ZoomSDKError_Success;
    BOOL resumeCamera = camera && self.sessionID && self.hasEnteredMeeting && [[[self.meeting getMeetingActionController] getMyself] isVideoOn];
    if (camera) {
        [self stopCameraEffectsPreview];
        if (resumeCamera) {
            NSInteger muted = [self setCameraEnabled:NO];
            if (muted != ZoomSDKError_Success) return muted;
            if ([[[self.meeting getMeetingActionController] getMyself] isVideoOn])
                return [self mediaControlResult:ZoomSDKError_ServiceFailed message:@"Zoom hasn’t confirmed that your camera is off yet. Try selecting the camera again."];
        }
    } else {
        NSInteger stopped = [self stopMediaTestKind:kind];
        if (stopped != ZoomSDKError_Success) return stopped;
    }
    ZoomSDKError result = camera ? [video selectCamera:deviceID] : [audio selectAudioDevice:microphone DeviceID:deviceID DeviceName:[selected getDeviceName] ?: @""];
    if (result == ZoomSDKError_Success) {
        NSArray *current = camera ? [video getCameraList] : [audio getAudioDeviceList:microphone];
        if (![[[self selectedMediaDevice:current] getDeviceID] isEqualToString:deviceID]) result = ZoomSDKError_ServiceFailed;
    }
    if (camera && result == ZoomSDKError_Success) {
        result = (ZoomSDKError)(resumeCamera ? [self setCameraEnabled:YES] :
            [self applyCameraBackground:self.preferredCameraBackground imagePath:self.preferredCameraImagePath autoFraming:self.preferredCameraAutoFraming]);
    }
    [self mediaControlResult:result message:camera && self.cameraEffectsError.length ? self.cameraEffectsError : @"Zoom couldn’t switch to that device. Check its connection and try again."];
    if (camera && self.sessionID && self.hasEnteredMeeting) [self refreshParticipants];
    return result;
}

- (NSInteger)setMediaVolume:(NSInteger)volume kind:(NSString *)kind {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    self.mediaDevicesError = nil;
    if (![self mediaControlsReady]) return ZoomSDKError_WrongUsage;
    BOOL microphone = [kind isEqualToString:@"microphone"];
    if ((!microphone && ![kind isEqualToString:@"speaker"]) || volume < 0 || volume > 100) return ZoomSDKError_InvalidParameter;
    ZoomSDKAudioSetting *audio = [[[ZoomSDK sharedSDK] getSettingService] getAudioSetting];
    if (![self selectedMediaDevice:[audio getAudioDeviceList:microphone]]) return ZoomSDKError_ServiceFailed;
    if (microphone && [audio isAutoAdjustMicOn]) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = [audio setAudioDeviceVolume:microphone Volume:(float)volume];
    float actual = [audio getAudioDeviceVolume:microphone];
    if (result == ZoomSDKError_Success && (!isfinite(actual) || fabsf(actual - volume) > 1.0f)) result = ZoomSDKError_ServiceFailed;
    return [self mediaControlResult:result message:@"Zoom couldn’t change this device’s volume. Adjust it on the device or in System Settings."];
}

- (NSInteger)setMicrophoneAutoGain:(BOOL)enabled {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    self.mediaDevicesError = nil;
    if (![self mediaControlsReady]) return ZoomSDKError_WrongUsage;
    ZoomSDKAudioSetting *audio = [[[ZoomSDK sharedSDK] getSettingService] getAudioSetting];
    if (!audio) return ZoomSDKError_ServiceFailed;
    ZoomSDKError result = [audio enableAutoAdjustMic:enabled];
    if (result == ZoomSDKError_Success && [audio isAutoAdjustMicOn] != enabled) result = ZoomSDKError_ServiceFailed;
    return [self mediaControlResult:result message:@"Zoom couldn’t change automatic microphone volume. Try again after reconnecting your microphone."];
}

- (void)playMediaMicrophoneRecording:(NSUUID *)token {
    if (![self mediaControlsReady] || self.mediaMicrophoneTestToken != token || [self.mediaMicrophoneTestState isEqualToString:@"playing"]) return;
    self.mediaMicrophoneTestState = @"playing";
    self.mediaMicrophoneNeedsRecordingStop = NO;
    ZoomSDKSettingTestMicrophoneDeviceHelper *helper = self.mediaMicrophoneHelper;
    WHZoomMediaObserver *observer = self.mediaMicrophoneObserver;
    NSUUID *generation = self.mediaGeneration;
    NSString *deviceID = self.mediaMicrophoneTestDeviceID;
    observer.testStartConfirmed = NO;
    ZoomSDKError result = [helper playRecordedMic];
    if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaMicrophoneTestToken != token || self.mediaMicrophoneHelper != helper) {
        [self stopCancelledMediaStart:helper microphone:YES generation:generation deviceID:deviceID];
        return;
    }
    ZoomSDKTestMicStatus actual = [helper getTestMicStatus];
    if (result == ZoomSDKError_Success && actual != testMic_Playing) result = ZoomSDKError_ServiceFailed;
    WHZoomLogMediaTest(YES, 6, actual, result);
    observer.testStartConfirmed = result == ZoomSDKError_Success;
    if (result != ZoomSDKError_Success) {
        [self stopMediaTestKind:@"microphone"];
        self.mediaDevicesError = @"Zoom couldn’t play the microphone test. Try again with another microphone.";
        [self emit:@"controlError" object:@"Zoom couldn’t play the microphone test. Try again with another microphone."];
    }
    else {
        __weak typeof(self) weakSelf = self;
        NSUUID *generation = self.mediaGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaMicrophoneTestToken != token) return;
            [self stopMediaTestKind:@"microphone"]; [self emitMediaDevices];
        });
    }
    [self emitMediaDevices];
}

- (void)finishMediaMicrophoneRecording:(NSUUID *)token {
    if (![self mediaControlsReady] || self.mediaMicrophoneTestToken != token || ![self.mediaMicrophoneTestState isEqualToString:@"recording"]) return;
    ZoomSDKError result = [self.mediaMicrophoneHelper stopRecrodingMic];
    WHZoomLogMediaTest(YES, 5, [self.mediaMicrophoneHelper getTestMicStatus], result);
    if (result == ZoomSDKError_Success) [self playMediaMicrophoneRecording:token];
    else { [self stopMediaTestKind:@"microphone"]; [self mediaControlResult:result message:@"Zoom couldn’t finish the microphone recording. Try the test again."]; }
}

- (void)stopCancelledMediaStart:(id)helper microphone:(BOOL)microphone generation:(NSUUID *)generation deviceID:(NSString *)deviceID {
    // Stop can reenter an SDK Start that has not finished yet. If that Start
    // subsequently opens the device, recover only its still-owned helper;
    // never touch a new test or an SDK generation that has already closed.
    if (WHZoomNativeOwner != self || !self.initialized || self.mediaGeneration != generation) return;
    if (microphone) {
        if (self.mediaMicrophoneHelper || self.mediaMicrophoneTestToken) return;
        self.mediaMicrophoneHelper = helper; self.mediaMicrophoneTestToken = [NSUUID UUID];
        self.mediaMicrophoneNeedsRecordingStop = [helper getTestMicStatus] == testMic_Recording;
        self.mediaMicrophoneTestState = @"recording"; self.mediaMicrophoneTestDeviceID = deviceID;
    } else {
        if (self.mediaSpeakerHelper || self.mediaSpeakerTestToken) return;
        self.mediaSpeakerHelper = helper; self.mediaSpeakerTestToken = [NSUUID UUID];
        self.mediaSpeakerTestDeviceID = deviceID;
    }
    [helper setDelegate:nil];
    [self stopMediaTestKind:microphone ? @"microphone" : @"speaker"];
    [self emitMediaDevices];
}

- (NSInteger)setMediaTest:(NSString *)kind running:(BOOL)running {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    self.mediaDevicesError = nil;
    BOOL microphone = [kind isEqualToString:@"microphone"];
    if (!microphone && ![kind isEqualToString:@"speaker"]) return ZoomSDKError_InvalidParameter;
    if (![self mediaControlsReady]) return ZoomSDKError_WrongUsage;
    if (!running) { NSInteger result = [self stopMediaTestKind:kind]; return [self mediaControlResult:result message:@"Zoom couldn’t stop the device test. Close audio settings and try again."]; }
    if (self.mediaMicrophoneStopFailed || self.mediaSpeakerStopFailed) {
        NSInteger stopped = [self stopMediaTestsForTransition];
        if (stopped != ZoomSDKError_Success) return [self mediaControlResult:stopped message:@"Zoom hasn’t confirmed that the previous audio test stopped. Try Stop again."];
    }
    if (microphone ? self.mediaMicrophoneTestToken != nil : self.mediaSpeakerTestToken != nil) return ZoomSDKError_Success;
    if (microphone && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized)
        return [self mediaControlResult:ZoomSDKError_NoPermission message:@"Allow Yap microphone access in System Settings before testing the microphone."];
    ZoomSDKAudioSetting *audio = [[[ZoomSDK sharedSDK] getSettingService] getAudioSetting];
    SDKDeviceInfo *device = [self selectedMediaDevice:[audio getAudioDeviceList:microphone]];
    if (!device) return ZoomSDKError_ServiceFailed;
    NSString *deviceID = [[device getDeviceID] copy];
    // Avoid competing test playback while recording a new microphone sample.
    NSInteger stopped = [self stopMediaTestsForTransition];
    if (stopped != ZoomSDKError_Success) return [self mediaControlResult:stopped message:@"Zoom couldn’t stop the previous audio test. Close audio settings before trying again."];
    NSUUID *token = [NSUUID UUID], *generation = self.mediaGeneration;
    __weak typeof(self) weakSelf = self;
    WHZoomMediaObserver *observer = [WHZoomMediaObserver new];
    ZoomSDKError result;
    if (microphone) {
        ZoomSDKSettingTestMicrophoneDeviceHelper *helper = [audio getSettingMicrophoneTestHelper];
        if (!helper) return ZoomSDKError_ServiceFailed;
        self.mediaMicrophoneHelper = helper; self.mediaMicrophoneTestToken = token;
        self.mediaMicrophoneTestDeviceID = [device getDeviceID];
        self.mediaMicrophoneNeedsRecordingStop = YES;
        self.mediaMicrophoneTestState = @"recording"; self.mediaMicrophoneObserver = observer;
        observer.microphoneChanged = ^(ZoomSDKTestMicStatus status, BOOL afterStart) {
            [weakSelf onMain:^{
                typeof(self) self = weakSelf;
                if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaMicrophoneTestToken != token) return;
                WHZoomLogMediaTest(YES, afterStart ? 4 : 3, status, 0);
                // SDK Start resets its old test and emits stopped/idle before
                // recording. Keep those callbacks in their original phase,
                // even when they reach the main queue after Start returns.
                if (!afterStart) return;
                if (status == testMic_RecrodingStopped) [self playMediaMicrophoneRecording:token];
                else if (status == testMic_Playing) self.mediaMicrophoneTestState = @"playing";
                else if (status == testMic_Normal) {
                    self.mediaMicrophoneTestToken = nil;
                    self.mediaMicrophoneTestDeviceID = nil;
                    self.mediaMicrophoneHelper.delegate = nil;
                    self.mediaMicrophoneHelper = nil; self.mediaMicrophoneObserver = nil;
                    self.mediaMicrophoneTestState = @"idle";
                    self.mediaMicrophoneNeedsRecordingStop = NO; self.mediaMicrophoneStopFailed = NO;
                }
                [self emitMediaDevices];
            }];
        };
        WHZoomLogMediaTest(YES, 0, [helper getTestMicStatus], 0);
        helper.delegate = observer;
        WHZoomLogMediaTest(YES, 1, [helper getTestMicStatus], 0);
        if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaMicrophoneHelper != helper || self.mediaMicrophoneTestToken != token) return ZoomSDKError_WrongUsage;
        result = [helper startRecordingMic:deviceID];
        if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaMicrophoneHelper != helper || self.mediaMicrophoneTestToken != token) {
            [self stopCancelledMediaStart:helper microphone:YES generation:generation deviceID:deviceID];
            return ZoomSDKError_WrongUsage;
        }
        ZoomSDKTestMicStatus actual = [helper getTestMicStatus];
        self.mediaMicrophoneNeedsRecordingStop = actual == testMic_Recording;
        // The public SDK wrapper can return success even when its internal
        // recording start failed. Its state getter must confirm recording.
        if (result == ZoomSDKError_Success && actual != testMic_Recording) result = ZoomSDKError_ServiceFailed;
        WHZoomLogMediaTest(YES, 2, actual, result);
        observer.testStartConfirmed = result == ZoomSDKError_Success;
        if (result == ZoomSDKError_Success) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf finishMediaMicrophoneRecording:token];
        });
    } else {
        ZoomSDKSettingTestSpeakerDeviceHelper *helper = [audio getSettingSpeakerTestHelper];
        if (!helper) return ZoomSDKError_ServiceFailed;
        self.mediaSpeakerHelper = helper; self.mediaSpeakerTestToken = token; self.mediaSpeakerObserver = observer;
        self.mediaSpeakerTestDeviceID = [device getDeviceID];
        observer.speakerChanged = ^(BOOL testing, BOOL afterStart) {
            [weakSelf onMain:^{
                typeof(self) self = weakSelf;
                if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaSpeakerTestToken != token) return;
                WHZoomLogMediaTest(NO, afterStart ? 4 : 3, testing, 0);
                if (!afterStart) return;
                if (!testing) {
                    self.mediaSpeakerTestToken = nil;
                    self.mediaSpeakerTestDeviceID = nil;
                    self.mediaSpeakerHelper.delegate = nil;
                    self.mediaSpeakerHelper = nil; self.mediaSpeakerObserver = nil;
                    self.mediaSpeakerStopFailed = NO;
                }
                [self emitMediaDevices];
            }];
        };
        WHZoomLogMediaTest(NO, 0, helper.isSpeakerInTesting, 0);
        helper.delegate = observer;
        WHZoomLogMediaTest(NO, 1, helper.isSpeakerInTesting, 0);
        if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaSpeakerHelper != helper || self.mediaSpeakerTestToken != token) return ZoomSDKError_WrongUsage;
        result = [helper SpeakerStartPlaying:deviceID];
        if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaSpeakerHelper != helper || self.mediaSpeakerTestToken != token) {
            [self stopCancelledMediaStart:helper microphone:NO generation:generation deviceID:deviceID];
            return ZoomSDKError_WrongUsage;
        }
        if (result == ZoomSDKError_Success && !helper.isSpeakerInTesting) result = ZoomSDKError_ServiceFailed;
        WHZoomLogMediaTest(NO, 2, helper.isSpeakerInTesting, result);
        observer.testStartConfirmed = result == ZoomSDKError_Success;
        if (result == ZoomSDKError_Success) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (![self mediaControlsReady] || self.mediaGeneration != generation || self.mediaSpeakerTestToken != token) return;
            [self stopMediaTestKind:@"speaker"]; [self emitMediaDevices];
        });
    }
    if (result != ZoomSDKError_Success) [self stopMediaTestKind:kind];
    return [self mediaControlResult:result message:microphone ? @"Zoom couldn’t start the microphone test. Check microphone access and its connection." : @"Zoom couldn’t start the speaker test. Check the speaker connection."];
}

- (NSInteger)setHandRaised:(BOOL)raised {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    if (WHZoomNativeOwner != self || !self.sessionID || !self.hasEnteredMeeting || self.ending || [self.meeting getMeetingStatus] != ZoomSDKMeetingStatus_InMeeting) return ZoomSDKError_WrongUsage;
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    ZoomSDKUserInfo *myself = [action getMyself];
    if (!myself || ![myself getUserID]) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = [action raiseHand:raised UserID:[myself getUserID]];
    [self refreshParticipants]; return result;
}

- (NSInteger)prepareCameraEffectsWithJWT:(NSString *)jwt completion:(void (^)(NSInteger, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    if (WHZoomNativeOwner && WHZoomNativeOwner != self) return ZoomSDKError_WrongUsage;
    if (self.cameraEffectsReady && !self.ending) { completion(0, nil); return 0; }
    if (self.initialized || self.sessionID || self.cameraPreparationCompletion) return ZoomSDKError_WrongUsage;
    self.cameraSettingsOnly = YES;
    self.cameraPreparationCompletion = completion;
    self.cameraPreparationToken = [NSUUID UUID];
    NSUUID *token = self.cameraPreparationToken;
    ZoomSDKInitParams *params = [ZoomSDKInitParams new];
    params.needCustomizedUI = YES; params.enableLog = NO; params.zoomDomain = @"zoom.us";
    ZoomSDKError result = [[ZoomSDK sharedSDK] initSDKWithParams:params];
    if (result != ZoomSDKError_Success) {
        self.cameraPreparationCompletion = nil; self.cameraPreparationToken = nil; self.cameraSettingsOnly = NO;
        return result;
    }
    self.initialized = YES; WHZoomNativeOwner = self;
    ZoomSDKAuthService *auth = [[ZoomSDK sharedSDK] getAuthService];
    auth.delegate = self;
    ZoomSDKAuthContext *context = [ZoomSDKAuthContext new]; context.jwtToken = jwt;
    result = [auth sdkAuth:context];
    if (result != ZoomSDKError_Success) {
        self.cameraPreparationCompletion = nil; [self closeCameraEffects]; return result;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || !self.cameraSettingsOnly || self.cameraPreparationToken != token) return;
        void (^callback)(NSInteger, NSString *) = self.cameraPreparationCompletion;
        self.cameraPreparationCompletion = nil;
        [self closeCameraEffects];
        if (callback) callback(ZoomSDKError_ServiceFailed, @"Zoom camera settings timed out. Check your connection and try again.");
    });
    return ZoomSDKError_Success;
}

- (NSString *)cameraBackgroundKind:(ZoomSDKVirtualBGImageInfo *)item {
    if (!item || [item isVideo] || [item isAllowDelete]) return nil;
    for (NSString *value in @[[item getImageName] ?: @"", [item getImageFilePath] ?: @""]) {
        NSString *name = value.uppercaseString;
        if ([name isEqualToString:@"NONE"] || [name isEqualToString:@"NEWUI_SETTINGS_NONE"]) return @"none";
        if ([name isEqualToString:@"BLUR"]) return @"blur";
    }
    return nil;
}

- (ZoomSDKVirtualBGImageInfo *)cameraBackgroundItem:(NSString *)kind path:(NSString *)path {
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *alias = self.cameraImageAliases[standardPath ?: @""];
    NSArray *items = [[[[ZoomSDK sharedSDK] getSettingService] getVirtualBGSetting] getBGItemList];
    for (ZoomSDKVirtualBGImageInfo *item in items) {
        if ([kind isEqualToString:[self cameraBackgroundKind:item]]) return item;
        if (![kind isEqualToString:@"image"] || [item isVideo]) continue;
        NSString *itemPath = [item getImageFilePath].stringByStandardizingPath;
        if (itemPath.length && ([itemPath isEqualToString:standardPath] || [itemPath isEqualToString:alias])) return item;
    }
    // Zoom may copy an imported image. Recover its identity after SDK/app restart
    // using the bytes, never an ambiguous filename shared by different photos.
    if ([kind isEqualToString:@"image"] && standardPath.length) {
        NSData *source = [NSData dataWithContentsOfFile:standardPath options:NSDataReadingMappedIfSafe error:nil];
        if (source.length) for (ZoomSDKVirtualBGImageInfo *item in items) {
            if ([item isVideo] || [self cameraBackgroundKind:item] || ![item getImageFilePath].length) continue;
            NSString *itemPath = [item getImageFilePath].stringByStandardizingPath;
            NSData *imported = [NSData dataWithContentsOfFile:itemPath options:NSDataReadingMappedIfSafe error:nil];
            if ([source isEqualToData:imported]) { self.cameraImageAliases[standardPath] = itemPath; return item; }
        }
    }
    return nil;
}

- (NSDictionary *)cameraEffectsState {
    BOOL ready = self.cameraEffectsReady && WHZoomNativeOwner == self && !self.ending;
    ZoomSDKSettingService *settings = ready ? [[ZoomSDK sharedSDK] getSettingService] : nil;
    ZoomSDKVirtualBackgroundSetting *background = [settings getVirtualBGSetting];
    ZoomSDKVideoSetting *video = [settings getVideoSetting];
    BOOL smart = background && [background isSupportVirtualBG] && [background isDeviceSupportSmartVirtualBG];
    BOOL inMeeting = self.sessionID && !self.cameraSettingsOnly && [self.meeting getMeetingStatus] == ZoomSDKMeetingStatus_InMeeting;
    NSMutableDictionary *value = [@{@"supportsBlur":@(smart && [self cameraBackgroundItem:@"blur" path:nil] != nil),
        @"supportsImageBackgrounds":@(smart), @"canAddImages":@(smart && [background isAllowAddNewVBItem]),
        @"isInMeeting":@(inMeeting), @"isCameraOn":@(inMeeting && [[[self.meeting getMeetingActionController] getMyself] isVideoOn]),
        @"isPreviewing":@(self.cameraPreviewHost != nil)} mutableCopy];
    if (self.cameraPreviewError.length) value[@"previewError"] = self.cameraPreviewError;
    if (!video) return value;
    NSString *kind = nil, *imagePath = nil;
    for (ZoomSDKVirtualBGImageInfo *item in [background getBGItemList]) if ([item isSelected]) {
        kind = [self cameraBackgroundKind:item];
        if (!kind && ![item isVideo] && [item getImageFilePath].length) {
            kind = @"image"; imagePath = [item getImageFilePath].stringByStandardizingPath;
            NSString *confirmed = self.confirmedCameraImagePath;
            if (confirmed.length && ([confirmed isEqualToString:imagePath] || [self.cameraImageAliases[confirmed] isEqualToString:imagePath])) {
                imagePath = confirmed;
            } else for (NSString *original in [self.cameraImageAliases.allKeys sortedArrayUsingSelector:@selector(compare:)]) if ([self.cameraImageAliases[original] isEqualToString:imagePath]) {
                imagePath = original; break;
            }
        }
        break;
    }
    if (!kind && (!background || ![background isSupportVirtualBG]) && [background getBGItemList].count == 0) kind = @"none";
    if (kind) {
        NSMutableDictionary *applied = [@{@"background":kind,
            @"autoFraming":@([video isVideoAutoFramingEnabled] && [video getVideoAutoFramingMode] == ZoomSDKAutoFramingMode_Face_Recognition)} mutableCopy];
        if (imagePath) applied[@"imagePath"] = imagePath;
        value[@"applied"] = applied;
    }
    return value;
}

- (NSData *)cameraEffectsSnapshot {
    return [NSJSONSerialization dataWithJSONObject:[self cameraEffectsState] options:0 error:nil] ?: [NSData data];
}

- (void)emitCameraEffects {
    [self onMain:^{
        if (WHZoomNativeOwner != self || !self.cameraEffectsReady || self.ending) return;
        if (self.cameraEffectsChanged) self.cameraEffectsChanged([self cameraEffectsSnapshot]);
    }];
}

- (NSInteger)failCameraEffect:(NSString *)message code:(NSInteger)code {
    self.cameraEffectsError = message;
    [self emitCameraEffects];
    return code ?: ZoomSDKError_Failed;
}

- (NSInteger)applyCameraBackground:(NSString *)kind imagePath:(NSString *)path autoFraming:(BOOL)autoFraming {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    self.cameraEffectsError = nil; self.cameraEffectsAwaitingConfirmation = NO;
    if (!self.cameraEffectsReady || WHZoomNativeOwner != self || self.ending) {
        return [self failCameraEffect:@"Camera settings are not ready. Reopen Camera settings and try again." code:ZoomSDKError_WrongUsage];
    }
    if (![@[@"none", @"blur", @"image"] containsObject:kind]) return ZoomSDKError_InvalidParameter;
    ZoomSDKSettingService *settings = [[ZoomSDK sharedSDK] getSettingService];
    ZoomSDKVirtualBackgroundSetting *background = [settings getVirtualBGSetting];
    ZoomSDKVideoSetting *video = [settings getVideoSetting];
    if (!video) return [self failCameraEffect:@"Zoom’s camera settings are unavailable. Try again after reconnecting." code:ZoomSDKError_ServiceFailed];
    BOOL needsBackground = ![kind isEqualToString:@"none"];
    if (needsBackground && (!background || ![background isSupportVirtualBG] || ![background isDeviceSupportSmartVirtualBG])) {
        return [self failCameraEffect:@"Zoom can’t use this background without a green screen on this camera or computer. Choose None or try a different camera." code:ZoomSDKError_UnSupportedFeature];
    }
    ZoomSDKVirtualBGImageInfo *item = [self cameraBackgroundItem:kind path:path];
    if ([kind isEqualToString:@"image"] && !item) {
        if (!path.length || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
            return [self failCameraEffect:@"The background photo is no longer available. Choose the photo again in Camera settings." code:ZoomSDKError_InvalidParameter];
        }
        if (![background isAllowAddNewVBItem]) return [self failCameraEffect:@"Your Zoom account doesn’t allow adding background photos. Choose None or Blur, or contact your Zoom administrator." code:ZoomSDKError_NoPermission];
        NSMutableSet *oldPaths = [NSMutableSet set];
        for (ZoomSDKVirtualBGImageInfo *existing in [background getBGItemList]) if ([existing getImageFilePath]) [oldPaths addObject:[existing getImageFilePath]];
        ZoomSDKError added = [background addBGImage:path];
        if (added != ZoomSDKError_Success) return [self failCameraEffect:@"Zoom couldn’t add this photo. Choose a JPEG or PNG image and try again." code:added];
        item = [self cameraBackgroundItem:kind path:path];
        if (!item) {
            NSMutableArray *newItems = [NSMutableArray array];
            for (ZoomSDKVirtualBGImageInfo *candidate in [background getBGItemList]) if (![candidate isVideo] && [candidate getImageFilePath].length && ![oldPaths containsObject:[candidate getImageFilePath]]) [newItems addObject:candidate];
            if (newItems.count == 1) item = newItems.firstObject;
        }
        if (item && [item getImageFilePath].length) self.cameraImageAliases[path.stringByStandardizingPath] = [item getImageFilePath].stringByStandardizingPath;
    }
    if (!item && (needsBackground || [background isSupportVirtualBG] || [background getBGItemList].count > 0)) return [self failCameraEffect:@"Zoom hasn’t made that background available yet. Reopen Camera settings and try again." code:ZoomSDKError_ServiceFailed];

    // Never disable the current background while preparing a replacement.
    ZoomSDKError result = ZoomSDKError_Success;
    if (needsBackground && [background isUsingGreenScreenOn]) {
        result = [background setUsingGreenScreen:NO];
        if (result != ZoomSDKError_Success) return [self failCameraEffect:@"Zoom couldn’t switch to a background without a green screen. Try again in Camera settings." code:result];
    }
    if (autoFraming && (![video isVideoAutoFramingEnabled] || [video getVideoAutoFramingMode] != ZoomSDKAutoFramingMode_Face_Recognition)) {
        ZoomSDKAutoFramingParameter *parameters = [ZoomSDKAutoFramingParameter new];
        parameters.ratio = 1.2; parameters.failStrategy = ZoomSDKFaceRecognitionFailStrategy_Remain;
        result = [video enableVideoAutoFraming:ZoomSDKAutoFramingMode_Face_Recognition setting:parameters];
    } else if (!autoFraming && [video isVideoAutoFramingEnabled]) result = [video disableVideoAutoFraming];
    if (result != ZoomSDKError_Success) {
        return [self failCameraEffect:@"Zoom couldn’t apply automatic framing. Turn Automatic framing off in Camera settings or try again." code:result];
    }
    if (item && ![item isSelected]) result = [background useBGItem:item];
    ZoomSDKVirtualBGImageInfo *selected = [self cameraBackgroundItem:kind path:path];
    [self logConnection:"camera-background-selection" code:result status:[selected isSelected]
                 reason:[kind isEqualToString:@"image"] ? 2 : ([kind isEqualToString:@"blur"] ? 1 : 0)];
    if (result != ZoomSDKError_Success) {
        return [self failCameraEffect:@"Zoom couldn’t select that background. Try again in Camera settings before turning on your camera." code:result];
    }
    return [self confirmCameraBackground:kind imagePath:path autoFraming:autoFraming];
}

- (NSInteger)confirmCameraBackground:(NSString *)kind imagePath:(NSString *)path autoFraming:(BOOL)autoFraming {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    self.cameraEffectsError = nil; self.cameraEffectsAwaitingConfirmation = NO;
    if (!self.cameraEffectsReady || WHZoomNativeOwner != self || self.ending) {
        return [self failCameraEffect:@"Camera settings are not ready. Reopen Camera settings and try again." code:ZoomSDKError_WrongUsage];
    }
    if (![@[@"none", @"blur", @"image"] containsObject:kind]) return ZoomSDKError_InvalidParameter;
    ZoomSDKSettingService *settings = [[ZoomSDK sharedSDK] getSettingService];
    ZoomSDKVirtualBackgroundSetting *background = [settings getVirtualBGSetting];
    ZoomSDKVideoSetting *video = [settings getVideoSetting];
    if (!video) return [self failCameraEffect:@"Zoom’s camera settings are unavailable. Try again after reconnecting." code:ZoomSDKError_ServiceFailed];
    BOOL needsBackground = ![kind isEqualToString:@"none"];
    if (needsBackground && (!background || ![background isSupportVirtualBG] || ![background isDeviceSupportSmartVirtualBG])) {
        return [self failCameraEffect:@"Zoom can’t use this background without a green screen on this camera or computer. Choose None or try a different camera." code:ZoomSDKError_UnSupportedFeature];
    }
    ZoomSDKVirtualBGImageInfo *selected = [self cameraBackgroundItem:kind path:path];
    BOOL backgroundConfirmed = [selected isSelected] || (!needsBackground && ![background isSupportVirtualBG] && [background getBGItemList].count == 0);
    BOOL framingConfirmed = [video isVideoAutoFramingEnabled] == autoFraming && (!autoFraming || [video getVideoAutoFramingMode] == ZoomSDKAutoFramingMode_Face_Recognition);
    if (!backgroundConfirmed || !framingConfirmed || (needsBackground && [background isUsingGreenScreenOn])) {
        self.cameraEffectsAwaitingConfirmation = YES;
        return [self failCameraEffect:@"Zoom hasn’t confirmed the requested camera effects yet. Try again before turning on your camera." code:ZoomSDKError_ServiceFailed];
    }
    self.confirmedCameraImagePath = [kind isEqualToString:@"image"] ? path.stringByStandardizingPath : nil;
    [self emitCameraEffects];
    return ZoomSDKError_Success;
}

- (NSView *)startCameraEffectsPreview {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    if (self.cameraPreviewHost) return self.cameraPreviewHost;
    self.cameraPreviewError = nil;
    if (!self.cameraSettingsOnly || self.sessionID) {
        [self failCameraEffect:@"Use your meeting self-view to check camera effects. Local preview is available before joining a meeting." code:ZoomSDKError_WrongUsage]; return nil;
    }
    if (!self.cameraEffectsReady || WHZoomNativeOwner != self || self.ending ||
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
        [self failCameraEffect:@"Allow Yap camera access in System Settings, then try Preview again." code:ZoomSDKError_NoPermission]; return nil;
    }
    ZoomSDKVideoSetting *videoSettings = [[[ZoomSDK sharedSDK] getSettingService] getVideoSetting];
    NSArray *devices = [videoSettings getCameraList];
    SDKDeviceInfo *selected = nil;
    for (SDKDeviceInfo *device in devices) if ([device isSelectedDevice] && [device getDeviceID].length) { selected = device; break; }
    [self logConnection:"camera-preview-devices" code:0 status:devices.count reason:selected != nil];
    if (!selected) {
        SDKDeviceInfo *fallback = nil;
        for (SDKDeviceInfo *device in devices) if ([device getDeviceID].length) { fallback = device; break; }
        if (!fallback) { [self failCameraEffect:@"No camera is available. Connect a camera and try Preview again." code:ZoomSDKError_ServiceFailed]; return nil; }
        ZoomSDKError selectedResult = [videoSettings selectCamera:[fallback getDeviceID]];
        if (selectedResult != ZoomSDKError_Success) { [self failCameraEffect:@"Zoom couldn’t select an available camera. Reconnect the camera and try again." code:selectedResult]; return nil; }
    }
    if ([self applyCameraBackground:self.preferredCameraBackground imagePath:self.preferredCameraImagePath autoFraming:self.preferredCameraAutoFraming] != 0) return nil;
    return [self createStandaloneCameraPreview:videoSettings];
}

- (NSView *)createStandaloneCameraPreview:(ZoomSDKVideoSetting *)videoSettings {
    // Zoom's standalone Settings sample uses the device-test helper. The
    // meeting preview element is documented for the connecting meeting UI.
    ZoomSDKSettingTestVideoDeviceHelper *helper = [videoSettings getSettingVideoTestHelper];
    if (!helper) { [self failCameraEffect:@"Zoom’s camera preview is unavailable. Reopen Camera settings and try again." code:ZoomSDKError_ServiceFailed]; return nil; }
    WHZoomRenderHost *host = [[WHZoomRenderHost alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
    self.cameraPreviewHost = host; self.cameraPreviewHelper = helper;
    self.cameraPreviewStarted = NO; self.cameraPreviewStartScheduled = NO; self.cameraPreviewBound = NO;
    NSUInteger revision = ++self.cameraPreviewRevision;
    __weak typeof(self) weakSelf = self;
    __weak WHZoomRenderHost *weakHost = host;
    __weak ZoomSDKSettingTestVideoDeviceHelper *weakHelper = helper;
    host.resizeRenderer = ^(NSRect rect) {
        typeof(self) self = weakSelf;
        if (!self || WHZoomNativeOwner != self || self.cameraPreviewHelper != weakHelper || self.cameraPreviewRevision != revision) return;
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
            [self failCameraPreview:@"Camera permission is unavailable. Allow Yap camera access in System Settings and try again."]; return;
        }
        // Native view appearance can itself activate the SDK preview. Even a
        // canceled/partially failed binding must therefore receive StopPreview.
        self.cameraPreviewBound = YES;
        ZoomSDKError result = [weakHelper SetVideoParentView:weakHost VideoContainerRect:rect];
        [self logConnection:"camera-preview-settings-parent" code:result status:self.cameraPreviewStarted reason:0];
        if (result != ZoomSDKError_Success) [self failCameraPreview:@"Zoom couldn’t display a local preview. Reopen Camera settings and try again."];
    };
    host.reconcileRenderer = ^(BOOL ready) {
        typeof(self) self = weakSelf;
        if (!ready || !self || WHZoomNativeOwner != self || self.cameraPreviewHelper != weakHelper || self.cameraPreviewRevision != revision || self.cameraPreviewStarted || self.cameraPreviewStartScheduled) return;
        // Parent binding adds Zoom's own view/controller tree. Let AppKit
        // attach that tree before requesting capture, as the SDK sample does.
        self.cameraPreviewStartScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || WHZoomNativeOwner != self || self.cameraPreviewHelper != weakHelper || self.cameraPreviewHost != weakHost || self.cameraPreviewRevision != revision) return;
            self.cameraPreviewStartScheduled = NO;
            [weakHost layoutSubtreeIfNeeded];
            if (!weakHost.isReadyForRenderer || self.cameraPreviewStarted) return;
            if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
                [self failCameraPreview:@"Camera permission is unavailable. Allow Yap camera access in System Settings and try again."]; return;
            }
            [self logCameraPreviewGeometry:weakHost];
            self.cameraPreviewStarted = YES;
            ZoomSDKError result = [weakHelper StartPreview];
            [self logConnection:"camera-preview-settings-start" code:result status:0 reason:0];
            if (result == ZoomSDKError_WrongUsage) {
                // The SDK's viewDidAppear can start preview before this call.
                // Normalize via public APIs, never treat WrongUsage as success.
                ZoomSDKError stopped = [weakHelper StopPreview];
                [self logConnection:"camera-preview-settings-restart" code:stopped status:0 reason:0];
                if (WHZoomNativeOwner != self || self.cameraPreviewHelper != weakHelper || self.cameraPreviewHost != weakHost || self.cameraPreviewRevision != revision) return;
                if (stopped == ZoomSDKError_Success) {
                    result = [weakHelper StartPreview];
                    [self logConnection:"camera-preview-settings-start" code:result status:1 reason:0];
                }
            }
            if (result != ZoomSDKError_Success) [self failCameraPreview:@"Zoom couldn’t start a local preview. Close other camera previews and try again."];
        });
    };
    [host scheduleRendererUpdate];
    [self emitCameraEffects]; return host;
}

- (void)logCameraPreviewGeometry:(NSView *)host {
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:host];
    for (NSUInteger index = 0; index < views.count && index < 24; index++) {
        NSView *view = views[index];
        NSRect visible = NSIntersectionRect(view.bounds, view.visibleRect);
        os_log_info(WHZoomConnectionLog(), "camera-preview-surface class=%{public}@ width=%.0f height=%.0f visibleWidth=%.0f visibleHeight=%.0f hidden=%d layer=%d windowVisible=%d windowOccluded=%d",
            NSStringFromClass(view.class), view.bounds.size.width, view.bounds.size.height,
            visible.size.width, visible.size.height, view.hiddenOrHasHiddenAncestor,
            view.wantsLayer, view.window.visible, (view.window.occlusionState & NSWindowOcclusionStateVisible) == 0);
        [views addObjectsFromArray:view.subviews];
    }
}

- (void)failCameraPreview:(NSString *)message {
    [self stopCameraEffectsPreview];
    self.cameraPreviewError = message;
    [self emitCameraEffects];
}

- (void)stopCameraEffectsPreview {
    self.cameraPreviewError = nil;
    ZoomSDKSettingTestVideoDeviceHelper *helper = self.cameraPreviewHelper;
    WHZoomRenderHost *host = self.cameraPreviewHost;
    BOOL mayBeRunning = self.cameraPreviewStarted || self.cameraPreviewBound;
    self.cameraPreviewHelper = nil;
    self.cameraPreviewStarted = NO; self.cameraPreviewStartScheduled = NO; self.cameraPreviewBound = NO; self.cameraPreviewRevision += 1;
    self.cameraPreviewHost.resizeRenderer = nil; self.cameraPreviewHost.reconcileRenderer = nil;
    self.cameraPreviewHost = nil;
    if (helper && WHZoomNativeOwner == self) {
        if (mayBeRunning) {
            ZoomSDKError result = [helper StopPreview];
            [self logConnection:"camera-preview-settings-stop" code:result status:0 reason:0];
        }
        for (NSView *view in host.subviews.copy) [view removeFromSuperview];
    }
    [self emitCameraEffects];
}

- (void)closeCameraEffects {
    [self stopMediaTests];
    [self stopCameraEffectsPreview];
    if (!self.cameraSettingsOnly) return; // Never touch a real meeting's lifecycle or camera.
    void (^callback)(NSInteger, NSString *) = self.cameraPreparationCompletion;
    self.cameraPreparationCompletion = nil; self.cameraPreparationToken = nil;
    [self resetNative]; self.cameraSettingsOnly = NO;
    if (callback) callback(ZoomSDKError_WrongUsage, @"Camera settings were closed.");
}

- (void)onSelectedVBImageChanged { [self emitCameraEffects]; }
- (void)onVBImageDidDownloaded:(NSString *)path { [self emitCameraEffects]; }
- (void)onCameraStatusChanged:(ZoomSDKDeviceStatus)status {
    NSUUID *mediaGeneration = self.mediaGeneration;
    [self onMain:^{
        if (WHZoomNativeOwner != self || !self.initialized || self.mediaGeneration != mediaGeneration) return;
        [self logConnection:"camera-device-status" code:status status:self.cameraPreviewStarted reason:0];
        if (self.cameraPreviewHost && (status == Device_Error_Unknown || status == Device_Error_Found || status == No_Device)) {
            [self failCameraPreview:@"Zoom can’t read the camera. Check its connection and privacy shutter, close other camera apps, and try again."];
        } else [self emitCameraEffects];
        [self emitMediaDevices];
    }];
}
- (void)onSelectedCameraChanged:(NSString *)deviceID {
    NSUUID *generation = self.mediaGeneration;
    [self onMain:^{
        if (![self mediaControlsReady] || self.mediaGeneration != generation) return;
        [self emitCameraEffects]; [self emitMediaDevices];
    }];
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
    if (self.directShareRunning) return NO;
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
    [self stopMediaTests];
    if (message && !self.terminationMessage) self.terminationMessage = message;
    self.ending = YES;
    [self cancelConnectionWatchdog];
    if (self.directShareRunning && !self.leaveWatchdogArmed) {
        if (self.directShareCodeHandler) [self.directShareCodeHandler cancel];
        else if (self.directShareContentHandler) [self.directShareContentHandler cancel];
        else [self.directShareHelper stopDirectShare];
    }
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

- (NSInteger)beginRoomShareWithJWT:(NSString *)jwt sessionID:(NSString *)sessionID {
    if (self.sessionID) return ZoomSDKError_WrongUsage;
    self.roomShare = YES;
    return [self beginWithJWT:jwt zak:@"" meetingNumber:0 vanityID:nil passcode:nil registrantToken:nil
                 displayName:@"" host:NO sessionID:sessionID];
}

- (NSInteger)beginWithJWT:(NSString *)jwt zak:(NSString *)zak meetingNumber:(int64_t)meetingNumber
                vanityID:(NSString *)vanityID passcode:(NSString *)passcode
         registrantToken:(NSString *)registrantToken displayName:(NSString *)displayName
                    host:(BOOL)host sessionID:(NSString *)sessionID {
    NSAssert(NSThread.isMainThread, @"Zoom operations require the main thread");
    if (self.sessionID || self.initialized || (WHZoomNativeOwner && WHZoomNativeOwner != self)) return ZoomSDKError_WrongUsage;
    self.sessionID = sessionID; self.ending = NO; self.joinRequested = NO; self.hosting = host;
    self.hasEnteredMeeting = NO; self.terminalStatusObserved = NO; self.terminationMessage = nil;
    ZoomSDKInitParams *params = [ZoomSDKInitParams new];
    params.needCustomizedUI = !self.roomShare; params.enableLog = NO; params.zoomDomain = @"zoom.us";
    ZoomSDKError result = [[ZoomSDK sharedSDK] initSDKWithParams:params];
    [self logConnection:"init-return" code:result status:0 reason:0];
    if (result != ZoomSDKError_Success) { self.sessionID = nil; return result; }
    self.initialized = YES; WHZoomNativeOwner = self;
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
    if (WHZoomNativeOwner != self || !self.initialized) return;
    if (self.cameraSettingsOnly) {
        if (!self.cameraPreparationCompletion || !self.cameraPreparationToken) return;
        void (^callback)(NSInteger, NSString *) = self.cameraPreparationCompletion;
        self.cameraPreparationCompletion = nil; self.cameraPreparationToken = nil;
        if (result != ZoomSDKAuthError_Success) {
            // Exit the delegate stack before uninitializing an authentication attempt.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (WHZoomNativeOwner == self && self.cameraSettingsOnly) [self closeCameraEffects];
                callback(result, @"Zoom couldn’t prepare Camera settings. Check your Zoom sign-in and try again.");
            });
            return;
        }
        self.meeting = [[ZoomSDK sharedSDK] getMeetingService];
        self.cameraEffectsReady = self.meeting != nil;
        [self.meeting getVideoContainer].delegate = self;
        [[[[ZoomSDK sharedSDK] getSettingService] getVirtualBGSetting] setDelegate:self];
        [[[[ZoomSDK sharedSDK] getSettingService] getVideoSetting] setDelegate:self];
        [self installMediaDeviceObserver];
        callback(self.cameraEffectsReady ? 0 : ZoomSDKError_ServiceFailed,
            self.cameraEffectsReady ? nil : @"Zoom’s camera settings are unavailable. Please try again.");
        return; // Settings authorization must never reach the meeting join path.
    }
    if (!self.sessionID || self.ending || self.joinRequested) return;
    [self logConnection:"auth-result" code:result status:0 reason:0];
    if (result != ZoomSDKAuthError_Success) {
        [self terminateWithMessage:[NSString stringWithFormat:@"Zoom could not authenticate this app (SDK code %ld). Check your developer credentials.", (long)result]];
        return;
    }
    self.meeting = [[ZoomSDK sharedSDK] getMeetingService];
    if (!self.meeting) { [self terminateWithMessage:@"Zoom’s meeting service could not start."]; return; }
    self.cameraEffectsReady = YES;
    [[[[ZoomSDK sharedSDK] getSettingService] getVirtualBGSetting] setDelegate:self];
    [[[[ZoomSDK sharedSDK] getSettingService] getVideoSetting] setDelegate:self];
    [self installMediaDeviceObserver];
    [self stopMediaTests];
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
    if (!video || [video disableVideoJoinMeeting:YES] != ZoomSDKError_Success || ![video isMuteMyVideoWhenJoinMeetingOn]) {
        [self terminateWithMessage:@"Zoom could not confirm that your camera will stay off while joining. Please try again."];
        return;
    }
    ZoomSDKPremeetingService *cameraPremeeting = [[ZoomSDK sharedSDK] getPremeetingService];
    [cameraPremeeting enableForceAutoStartMyVideoWhenJoinMeeting:NO];
    [cameraPremeeting enableForceAutoStopMyVideoWhenJoinMeeting:YES];
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
    if (self.roomShare) {
        self.joinParameters = nil;
        // Direct Share's documented default-UI flow must ask what to share.
        // Never inherit Zoom's automatic whole-desktop sharing preference.
        if (!sharing || [sharing setShareOptionwWhenShareInDirectShare:ZoomSDKSettingShareScreenShareOption_AllOption] != ZoomSDKError_Success) {
            [self terminateWithMessage:@"Zoom could not prepare the screen-sharing picker. Nothing has been shared."];
            return;
        }
        ZoomSDKPremeetingService *premeeting = [[ZoomSDK sharedSDK] getPremeetingService];
        [premeeting enableForceAutoStopMyVideoWhenJoinMeeting:YES];
        [premeeting disableAutoShowSelectJoinAudioDlgWhenJoinMeeting:YES];
        self.directShareHelper = [premeeting getDirectShareHelper];
        ZoomSDKError availability = self.directShareHelper ? [self.directShareHelper canDirectShare] : ZoomSDKError_ServiceFailed;
        [self logConnection:"direct-share-eligibility" code:availability
                     status:[[[ZoomSDK sharedSDK] getAuthService] getAccountInfo] != nil reason:0];
        if (availability != ZoomSDKError_Success) {
            NSString *message = availability == ZoomSDKError_NoPermission
                ? @"Zoom’s meeting SDK rejected room pairing before discovery started (NoPermission, code 6). Open Zoom Workplace to pair with the room, or join its meeting in Yap and choose Share."
                : [NSString stringWithFormat:@"Yap couldn’t start Zoom Room pairing (SDK code %ld). No room search has started, and nothing has been shared. Please try again.", (long)availability];
            [self terminateWithMessage:message];
            return;
        }
        self.directShareHelper.delegate = self;
        self.joinRequested = YES;
        self.directShareRunning = YES;
        ZoomSDKError result = [self.directShareHelper startDirectShare];
        if (result != ZoomSDKError_Success) {
            self.directShareRunning = NO;
            [self terminateWithMessage:[NSString stringWithFormat:@"Zoom couldn’t start room sharing (SDK code %ld). Nothing has been shared. Please try again.", (long)result]];
        }
        return;
    }
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
- (NSInteger)submitRoomSharingCode:(NSString *)code {
    if (!self.roomShare || self.ending || !self.directShareCodeHandler) return ZoomSDKError_WrongUsage;
    ZoomSDKDirectShareHandler *handler = self.directShareCodeHandler;
    self.directShareCodeHandler = nil;
    BOOL numeric = code.length > 0 && [code rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
    ZoomSDKError result = numeric ? [handler inputMeetingNumber:code] : [handler inputSharingKey:code];
    if (result != ZoomSDKError_Success && !self.directShareCodeHandler) self.directShareCodeHandler = handler;
    return result;
}

- (void)onDirectShareStatusReceived:(DirectShareStatus)status DirectShareReceived:(ZoomSDKDirectShareHandler *)handler {
    [self onMain:^{
        if (!self.sessionID || !self.roomShare) return;
        if (status == DirectShareStatus_Ended) {
            self.directShareRunning = NO;
            self.directShareCodeHandler = nil;
            self.directShareContentHandler = nil;
            [self terminateWithMessage:self.terminationMessage];
            return;
        }
        if (self.ending) return;
        self.directShareCodeHandler = nil;
        switch (status) {
            case DirectShareStatus_NeedMeetingIDOrSharingKey:
            case DirectShareStatus_NeedInputNewPairingCode:
                self.directShareCodeHandler = handler;
                [self emit:@"roomShare" object:@"needsCode"];
                break;
            case DirectShareStatus_WrongMeetingIDOrSharingKey:
                self.directShareCodeHandler = handler;
                [self emit:@"roomShare" object:@"invalidCode"];
                break;
            case DirectShareStatus_Connecting:
                [self emit:@"roomShare" object:@"searching"];
                break;
            case DirectShareStatus_InProgress:
                self.directShareContentHandler = nil;
                [self emit:@"roomShare" object:@"sharing"];
                break;
            case DirectShareStatus_NetworkError:
                [self requestLeaveWithMessage:@"Zoom couldn’t connect to the room. Check that your Mac and the Zoom Room are on the same network, then try again." endMeeting:NO];
                break;
            default: break;
        }
    }];
}

- (void)onDirectShareSpecifyContent:(ZoomSDKDirectShareSpecifyContentHandler *)handler {
    [self onMain:^{
        if (!self.sessionID || !self.roomShare || self.ending) return;
        self.directShareCodeHandler = nil;
        self.directShareContentHandler = handler;
        [self emit:@"roomShare" object:@"choosingContent"];
    }];
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
    [self stopMediaTests];
    if (self.initialized && WHZoomNativeOwner == self)
        [[[[ZoomSDK sharedSDK] getSettingService] getAudioSetting] setDelegate:nil];
    self.mediaGeneration = nil; self.mediaDeviceObserver = nil; self.mediaDevicesError = nil;
    [self stopCameraEffectsPreview];
    self.cameraEffectsReady = NO;
    [self emitMediaDevices];
    self.cameraEffectsAwaitingConfirmation = NO;
    self.cameraPreparationToken = nil;
    [self.photoShutter invalidate]; self.photoShutter = nil;
    self.directShareHelper.delegate = nil;
    self.directShareHelper = nil;
    self.directShareCodeHandler = nil;
    self.directShareContentHandler = nil;
    self.directShareRunning = NO;
    self.roomShare = NO;
    [self.requestedAvatars removeAllObjects]; [self.avatarRevisions removeAllObjects];
    self.profilePicturesHidden = nil;
    self.cloudRecordingStartRequest = nil; self.cloudRecordingRequesterID = 0;
    self.lastCloudRecordingPayload = nil;
    self.chatFileSenders = nil; self.chatFileReceivers = nil; self.chatFileMetadata = nil; self.lastChatPolicy = nil;
    self.localShareActive = NO; self.sharingComputerAudio = NO; self.requestedComputerAudio = NO; self.awaitingShareSource = NO; self.shareSourceRevision += 1;
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
    if (self.initialized && WHZoomNativeOwner == self) {
        [[[[ZoomSDK sharedSDK] getSettingService] getVirtualBGSetting] setDelegate:nil];
        [[[[ZoomSDK sharedSDK] getSettingService] getVideoSetting] setDelegate:nil];
        [[ZoomSDK sharedSDK] getAuthService].delegate = nil;
        [[ZoomSDK sharedSDK] getReminderHelper].delegate = nil;
        [[ZoomSDK sharedSDK] unInitSDK];
        WHZoomNativeOwner = nil;
    }
    self.initialized = NO; self.joinRequested = NO; self.meeting = nil;
    self.mediaMicrophoneHelper = nil; self.mediaSpeakerHelper = nil;
    self.mediaMicrophoneTestToken = nil; self.mediaSpeakerTestToken = nil;
    self.mediaMicrophoneTestDeviceID = nil; self.mediaSpeakerTestDeviceID = nil;
    self.mediaMicrophoneObserver = nil; self.mediaSpeakerObserver = nil;
    self.mediaMicrophoneStopFailed = NO; self.mediaSpeakerStopFailed = NO;
    self.mediaMicrophoneNeedsRecordingStop = NO; self.mediaMicrophoneTestState = @"idle";
    self.joinParameters = nil; self.hostParameters = nil; self.appSignal = nil;
    self.terminationMessage = nil; self.hasEnteredMeeting = NO; self.terminalStatusObserved = NO;
    [self.indicators removeAllObjects];
}

- (void)onMeetingStatusChange:(ZoomSDKMeetingStatus)state meetingError:(ZoomSDKMeetingError)error EndReason:(EndMeetingReason)reason {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self onMeetingStatusChange:state meetingError:error EndReason:reason]; }); return;
    }
    if (!self.sessionID) return;
    // The premeeting service can report Idle while it listens for a room.
    if (self.roomShare && self.directShareRunning && state == ZoomSDKMeetingStatus_Idle && !self.ending) return;
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
            [self emitMediaDevices];
            [self refreshParticipants]; [self refreshWaitingRoom]; [self refreshShares]; [self refreshChatNotice];
            [self refreshIndicators];
            [self refreshCloudRecording];
            [self startVideoStatistics];
            {
                NSString *invitation = [self.meeting getMeetingProperty:MeetingPropertyCmd_JoinMeetingUrl];
                if (invitation.length) [self emit:@"invitation" object:invitation];
                // Connect playback while keeping the input muted through Zoom's join-VoIP setting.
                ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
                if (!self.roomShare && [[action getMyself] getAudioType] == ZoomSDKAudioType_None) {
                    [action actionMeetingWithCmd:ActionMeetingCmd_JoinVoip userID:0 onScreen:ScreenType_First];
                }
            }
            break;
        case ZoomSDKMeetingStatus_AudioReady: [self refreshParticipants]; [self emitMediaDevices]; break;
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
    [self refreshChatPolicy];
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
                           @"isSelf":@([user isMySelf]), @"isHost":@([user isHost]), @"isMuted":@(muted), @"handRaised":@([user isRaisingHand]),
                           @"isConferenceRoom":@([user isH323User]), @"isCameraEnabled":@([user isVideoOn]), @"isSpeaking":@([user isTalking])} mutableCopy];
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
                [self.videosReportingLiveData removeObject:identifier];
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
        if ([self applyCameraBackground:self.preferredCameraBackground imagePath:self.preferredCameraImagePath autoFraming:self.preferredCameraAutoFraming] != ZoomSDKError_Success) {
            return ZoomSDKError_ServiceFailed;
        }
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
- (NSDictionary *)chatPolicySnapshot {
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    ZoomSDKChatStatus *status = [action getChatStatus];
    ZoomSDKNormalMeetingChatPrivilege *normal = [status getNormalMeetingPrivilege];
    ZoomSDKWebinarAttendeeChatPrivilege *attendee = [status getWebinarAttendeePrivilege];
    ZoomSDKWebinarPanelistChatPrivilege *panelist = [status getWebinarPanelistPrivilege];
    ZoomSDKUserInfo *myself = [action getMyself];
    BOOL moderator = [myself isHost] || [myself getUserRole] == UserRole_CoHost;
    ZoomSDKMeetingChatController *chat = [self.meeting getMeetingChatController];
    return @{@"canEveryone":[NSNumber numberWithBool:normal ? normal.canChat && normal.canChatToAll : (attendee.canChat && attendee.canChatToAllPanellistAndAttendee) || panelist.canChatToAllPanellistAndAttendee],
        @"canPrivate":[NSNumber numberWithBool:normal ? normal.canChat && normal.canChatToIndividual : panelist.canChatToIndividual],
        @"onlyHost":[NSNumber numberWithBool:normal.canChat && normal.isOnlyCanChatToHost],
        @"canPanelists":[NSNumber numberWithBool:(attendee.canChat && attendee.canChatToAllPanellist) || panelist.canChatToAllPanellist],
        @"canWaitingRoom":[NSNumber numberWithBool:moderator && [[self.meeting getWaitingRoomController] isEnableWaitingRoomOnEntry]],
        @"canTransferFiles":[NSNumber numberWithBool:[chat isFileTransferEnabled]], @"allowedFileTypes":[chat getTransferFileTypeAllowList] ?: @"",
        @"maxFileBytes":@([chat getMaxTransferFileSizeBytes])};
}
- (void)refreshChatPolicy {
    if (!self.sessionID || self.ending || !self.hasEnteredMeeting) return;
    NSDictionary *policy = [self chatPolicySnapshot];
    if (![policy isEqual:self.lastChatPolicy]) { self.lastChatPolicy = policy; [self emit:@"chatPolicy" object:policy]; }
}
- (BOOL)canSendChatTo:(NSDictionary *)recipient {
    NSDictionary *policy = [self chatPolicySnapshot];
    NSString *kind = recipient[@"kind"];
    if ([kind isEqual:@"everyone"]) return [policy[@"canEveryone"] boolValue];
    if ([kind isEqual:@"waitingRoom"]) return [policy[@"canWaitingRoom"] boolValue];
    if ([kind isEqual:@"panelists"]) return [policy[@"canPanelists"] boolValue];
    if (![kind isEqual:@"participant"]) return NO;
    NSString *identifier = recipient[@"participantID"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
        [identifier rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound ||
        identifier.longLongValue <= 0 || identifier.longLongValue > UINT32_MAX) return NO;
    ZoomSDKUserInfo *user = [[self.meeting getMeetingActionController] getUserByUserID:(unsigned int)identifier.longLongValue];
    return user && ![user isMySelf] && ([policy[@"onlyHost"] boolValue] ? [user isHost] : [policy[@"canPrivate"] boolValue]);
}
- (NSInteger)sendChatMessage:(NSData *)payload {
    if (!self.sessionID || self.ending || !self.hasEnteredMeeting) return ZoomSDKError_WrongUsage;
    NSDictionary *draft = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![draft isKindOfClass:NSDictionary.class] || ![draft[@"recipient"] isKindOfClass:NSDictionary.class]) return ZoomSDKError_InvalidParameter;
    if (![self canSendChatTo:draft[@"recipient"]]) { [self refreshChatPolicy]; return ZoomSDKError_NoPermission; }
    ZoomSDKMeetingChatController *chat = [self.meeting getMeetingChatController];
    ZoomSDKChatInfo *message = WHZoomBuildChatMessage(draft, chat, [[[self.meeting getMeetingActionController] getMyself] getUserID]);
    return message ? [chat sendChatMsgTo:message] : ZoomSDKError_InvalidParameter;
}
- (NSInteger)sendChatText:(NSString *)text {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"text":text, @"recipient":@{@"kind":@"everyone", @"name":@"Everyone"}} options:0 error:nil];
    return [self sendChatMessage:data];
}
- (NSInteger)sendChatReply:(NSString *)text toMessage:(NSString *)messageID {
    ZoomSDKChatInfo *original = [[self.meeting getMeetingChatController] getChatMessageById:messageID];
    if (!original) return ZoomSDKError_WrongUsage;
    NSDictionary *target = WHZoomChatRecipient(original, [[[self.meeting getMeetingActionController] getMyself] getUserID], YES);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"text":text, @"recipient":target, @"replyToSDKID":messageID} options:0 error:nil];
    return [self sendChatMessage:data];
}
- (NSInteger)deleteChatMessage:(NSString *)messageID {
    ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
    ZoomSDKChatInfo *message = [[self.meeting getMeetingChatController] getChatMessageById:messageID];
    if (!self.sessionID || self.ending || !message || [message getSenderUserID] != [[action getMyself] getUserID] ||
        ![action isChatMessageCanBeDeleted:messageID]) return ZoomSDKError_NoPermission;
    return [action deleteChatMessage:messageID];
}
- (NSInteger)sendChatFile:(NSString *)path recipient:(NSData *)data {
    NSDictionary *recipient = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![recipient isKindOfClass:NSDictionary.class] || ![self canSendChatTo:recipient]) return ZoomSDKError_NoPermission;
    ZoomSDKMeetingChatController *chat = [self.meeting getMeetingChatController];
    if (!self.sessionID || self.ending || !self.hasEnteredMeeting || ![chat isFileTransferEnabled]) return ZoomSDKError_NoPermission;
    NSString *kind = recipient[@"kind"];
    if ([kind isEqual:@"everyone"]) return [chat transferFileToAll:path];
    if ([kind isEqual:@"participant"]) return [chat transferFile:path toUser:[recipient[@"participantID"] intValue]];
    return ZoomSDKError_UnSupportedFeature;
}
- (NSInteger)receiveChatFile:(NSString *)attachmentID path:(NSString *)path {
    ZoomSDKFileReceiver *receiver = self.chatFileReceivers[attachmentID];
    NSDictionary *previous = self.chatFileMetadata[attachmentID];
    if (!self.sessionID || self.ending || !receiver || !path.isAbsolutePath || !previous ||
        [previous[@"isFromSelf"] boolValue] || ![@[@"available", @"failed", @"cancelled"] containsObject:previous[@"status"]]) return ZoomSDKError_WrongUsage;
    NSString *session = [self.sessionID copy];
    // The receiver remains owned by this session after cancellation. Ask the
    // SDK to start again; its actual return value decides whether it can retry.
    // Clear cancellation suppression before calling, since progress can arrive
    // synchronously. Do not overwrite progress already delivered by the SDK.
    NSMutableDictionary *receiving = [previous mutableCopy];
    receiving[@"status"] = @"transferring"; receiving[@"progress"] = @0;
    self.chatFileMetadata[attachmentID] = receiving;
    ZoomSDKError result = [receiver startReceive:path];
    if ([self.sessionID isEqual:session] && self.chatFileMetadata[attachmentID] == receiving) {
        if (result == ZoomSDKError_Success) [self emit:@"chatAttachment" object:receiving];
        else self.chatFileMetadata[attachmentID] = previous;
    }
    return result;
}
- (NSInteger)cancelChatFile:(NSString *)attachmentID {
    if (!self.sessionID || self.ending) return ZoomSDKError_WrongUsage;
    ZoomSDKFileSender *sender = self.chatFileSenders[attachmentID];
    ZoomSDKFileReceiver *receiver = self.chatFileReceivers[attachmentID];
    ZoomSDKError result = sender ? [sender cancelSend] : receiver ? [receiver cancelReceive] : ZoomSDKError_WrongUsage;
    if (result == ZoomSDKError_Success && self.chatFileMetadata[attachmentID]) {
        NSMutableDictionary *metadata = [self.chatFileMetadata[attachmentID] mutableCopy]; metadata[@"status"] = @"cancelled";
        self.chatFileMetadata[attachmentID] = metadata; [self emit:@"chatAttachment" object:metadata];
    }
    return result;
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
    NSString *session = [self.sessionID copy];
    unsigned int selfID = [[[self.meeting getMeetingActionController] getMyself] getUserID];
    NSDictionary *recipient = WHZoomChatRecipient(chat, selfID, NO);
    NSDictionary *snapshot = @{@"id":[[chat getMessageID] copy] ?: @"", @"senderName":[[chat getSenderDisplayName] copy] ?: @"Participant",
        @"text":[[chat getMsgContent] copy] ?: @"", @"timestamp":@([chat getTimeStamp]),
        @"senderID":@([chat getSenderUserID]).stringValue, @"threadID":[[chat getThreadID] copy] ?: @"",
        @"isReply":[NSNumber numberWithBool:[chat isComment]], @"recipient":recipient, @"runs":WHZoomChatRuns(chat),
        @"canReply":[NSNumber numberWithBool:[chat isThread] || [chat isComment]], @"isFromSelf":[NSNumber numberWithBool:[chat getSenderUserID] == selfID],
        @"canDelete":[NSNumber numberWithBool:[chat getSenderUserID] == selfID && [[self.meeting getMeetingActionController] isChatMessageCanBeDeleted:[chat getMessageID]]]};
    [self onMain:^{
        if (!session || ![self.sessionID isEqual:session] || self.ending) return;
        [self emit:event object:snapshot];
    }];
}
- (void)refreshChatNotice {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshChatNotice]; }); return; }
    [self refreshChatPolicy];
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
    [self.videosReportingLiveData removeObject:identifier];
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
    [self.videosReportingLiveData removeObject:identifier];
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
                [self.videosReportingLiveData removeObject:identifier];
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
- (BOOL)isVideoReadyForCaptureForParticipant:(NSString *)participantID {
    ZoomSDKNormalVideoElement *element = self.videos[participantID];
    if (!self.sessionID || self.ending || !self.hasEnteredMeeting || !element ||
        element.userid != participantID.longLongValue || ![self.subscribedVideos containsObject:participantID] ||
        ![self.videosReportingLiveData containsObject:participantID] ||
        self.videoRetryTokens[participantID] || [self.videoRetryExhausted containsObject:participantID] ||
        !self.videoHosts[participantID].isReadyForRenderer || [element getDataType] != VideoRenderDataType_Video ||
        ![[[self.meeting getMeetingActionController] getUserByUserID:element.userid] isVideoOn]) return NO;
    // The SDK exposes a render-data-type callback, not a per-frame presentation
    // callback. Check its current video state and uncached stream geometry;
    // callers also allow the native window compositor time to present it.
    CGSize size = [self.meeting getUserVideoSize:element.userid];
    return isfinite(size.width) && isfinite(size.height) && size.width >= 1 && size.height >= 1 &&
        size.width <= 16384 && size.height <= 16384 && size.width / size.height >= 0.125 && size.width / size.height <= 8;
}
- (void)onRenderUserChanged:(ZoomSDKVideoElement *)element User:(unsigned int)userID {
    [self onMain:^{ [self logVideo:"render-user" element:element code:0]; [self refreshParticipants]; }];
}
- (void)onRenderDataTypeChanged:(ZoomSDKVideoElement *)element DataType:(VideoRenderDataType)type {
    [self onMain:^{
        NSString *identifier = element ? [self.videos allKeysForObject:(id)element].firstObject : nil;
        if (!identifier || !self.sessionID || self.ending) return;
        if (type == VideoRenderDataType_Video && [self.subscribedVideos containsObject:identifier]) {
            [self.videosReportingLiveData addObject:identifier];
        } else [self.videosReportingLiveData removeObject:identifier];
        [self logVideo:"render-data" element:element code:type]; [self refreshParticipants];
    }];
}
- (void)onSubscribeUserFail:(ZoomSDKVideoSubscribeFailReason)error videoElement:(ZoomSDKVideoElement *)element {
    [self onMain:^{
        if (!element || !self.sessionID || self.ending) return;
        NSString *identifier = [self.videos allKeysForObject:(id)element].firstObject;
        if (!identifier || ![self.subscribedVideos containsObject:identifier] || !self.videoHosts[identifier].isReadyForRenderer) return;
        if (error != ZoomSDKVideoSubscribe_Fail_None) [self.videosReportingLiveData removeObject:identifier];
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

- (BOOL)isWindowShareable:(uint32_t)windowID {
    if (self.roomShare) return [[self.directShareContentHandler getSupportedDirectShareType] containsObject:@(ZoomSDKShareContentType_AS)];
    return [[self.meeting getASController] isShareAppValid:windowID];
}
- (BOOL)isDesktopSharingEnabled {
    if (self.roomShare) return [[self.directShareContentHandler getSupportedDirectShareType] containsObject:@(ZoomSDKShareContentType_DS)];
    return [[self.meeting getASController] isDesktopSharingEnabled];
}
- (NSInteger)startSharingWindow:(uint32_t)windowID {
    if (self.photoShutter || self.sharingComputerAudio || self.requestedComputerAudio) return ZoomSDKError_WrongUsage;
    if (self.roomShare) {
        if (!self.directShareContentHandler || self.ending) return ZoomSDKError_WrongUsage;
        return [self.directShareContentHandler tryShareApplication:windowID shareSound:NO optimizeVideoClip:NO];
    }
    ZoomSDKASController *share = [self.meeting getASController];
    if (!share || ![share isShareAppValid:windowID]) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = [share startAppShare:windowID];
    [self logConnection:"share-window-return" code:result status:[self.meeting getMeetingStatus] reason:0];
    if (result == ZoomSDKError_Success) [self confirmRequestedShareWindow:windowID display:0];
    return result;
}
- (NSInteger)startSharingDisplay:(uint32_t)displayID {
    if (self.photoShutter || self.sharingComputerAudio || self.requestedComputerAudio) return ZoomSDKError_WrongUsage;
    if (self.roomShare) {
        if (!self.directShareContentHandler || self.ending) return ZoomSDKError_WrongUsage;
        return [self.directShareContentHandler tryShareDesktop:displayID shareSound:NO optimizeVideoClip:NO];
    }
    ZoomSDKASController *share = [self.meeting getASController];
    if (!share || ![share isDesktopSharingEnabled]) return ZoomSDKError_WrongUsage;
    ZoomSDKError result = [share startMonitorShare:displayID];
    [self logConnection:"share-display-return" code:result status:[self.meeting getMeetingStatus] reason:0];
    if (result == ZoomSDKError_Success) [self confirmRequestedShareWindow:0 display:displayID];
    return result;
}
- (BOOL)isComputerAudioSharingEnabled {
    return !self.roomShare && !self.ending && [[self.meeting getASController] isAbleToShareComputerAudio];
}
- (NSInteger)startSharingComputerAudio {
    // Audio-only must never silently retain an existing screen broadcast.
    if (self.photoShutter || self.localShareActive || self.requestedComputerAudio || ![self isComputerAudioSharingEnabled]) return ZoomSDKError_WrongUsage;
    ZoomSDKASController *share = [self.meeting getASController];
    ZoomSDKError result = [share setAudioShareMode:ZoomSDKAudioShareMode_Stereo];
    if (result != ZoomSDKError_Success) return result;
    self.requestedComputerAudio = YES;
    result = [share startAudioShare];
    if (result != ZoomSDKError_Success) self.requestedComputerAudio = NO;
    [self logConnection:"share-audio-return" code:result status:[self.meeting getMeetingStatus] reason:0];
    return result;
}
- (NSInteger)preparePhotoShutter:(NSData *)pcm {
    if (self.photoShutter || self.localShareActive || self.requestedComputerAudio || self.roomShare || self.ending ||
        !self.sessionID || !self.meeting || pcm.length == 0 || pcm.length > 88200 || pcm.length % 2) return ZoomSDKError_WrongUsage;
    ZoomSDKRawDataShareSourceController *source = nil;
    ZoomSDKError result = [[[ZoomSDK sharedSDK] getRawDataController] getRawDataShareSourceHelper:&source];
    if (result != ZoomSDKError_Success || !source) return result == ZoomSDKError_Success ? ZoomSDKError_UnSupportedFeature : result;
    WHPhotoShutterAudio *audio = [WHPhotoShutterAudio new];
    audio.pcm = pcm;
    __weak typeof(self) weakSelf = self;
    __weak WHPhotoShutterAudio *weakAudio = audio;
    audio.finished = ^{
        if (weakAudio.failed) [weakSelf emit:@"controlError" object:@"Zoom couldn’t send the shutter sound to the meeting."];
        [weakSelf cancelPhotoShutter];
    };
    audio.stopped = ^{
        if (weakSelf.photoShutter == weakAudio) weakSelf.photoShutter = nil;
    };
    self.photoShutter = audio;
    result = [source setSharePureAudioSource:audio];
    if (result != ZoomSDKError_Success) { [audio invalidate]; self.photoShutter = nil; }
    return result;
}
- (BOOL)isPhotoShutterReady { return self.photoShutter.sender != nil; }
- (BOOL)playPhotoShutter {
    if (!self.photoShutter.sender) return NO;
    self.photoShutter.playing = YES;
    return YES;
}
- (void)cancelPhotoShutter {
    if (!self.photoShutter || self.photoShutter.stopping) return;
    self.photoShutter.stopping = YES;
    [self.photoShutter invalidate];
    // Keep the delegate retained through stopShare, including synchronous SDK callbacks.
    [[self.meeting getASController] stopShare];
    // onStopSendAudio releases the delegate after the SDK is finished with it.
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
    if (self.sharingComputerAudio) {
        [self emit:@"sharing" object:@{@"active":@YES, @"computerAudio":@YES}];
        return;
    }
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
    if (self.photoShutter && (status == ZoomSDKShareStatus_SelfStartAudioShare || status == ZoomSDKShareStatus_SelfStopAudioShare)) return;
    // An audio-ended callback accompanying a screen share must not hide its Stop control.
    if (status == ZoomSDKShareStatus_SelfStopAudioShare && !self.sharingComputerAudio && !self.requestedComputerAudio) return;
    WHZoomLocalShareUpdate update = WHZoomLocalShareUpdateForStatus(status, ownerID, localID);
    // No window/display/user identifiers or titles enter diagnostics.
    os_log_info(WHZoomConnectionLog(), "share=status status=%{public}ld update=%{public}lu ownerPresent=%{public}d localOwner=%{public}d windowPresent=%{public}d displayPresent=%{public}d",
        (long)status, (unsigned long)update, ownerID != 0, ownerID != 0 && ownerID == localID, windowID != 0, displayID != 0);
    switch (update) {
        case WHZoomLocalShareUpdateActive:
            self.localShareActive = YES;
            if (status == ZoomSDKShareStatus_SelfStartAudioShare || self.requestedComputerAudio) {
                self.sharingComputerAudio = YES;
                self.requestedComputerAudio = NO;
                self.awaitingShareSource = NO;
                self.shareSourceRevision += 1;
            }
            [self publishLocalShareWindow:windowID display:displayID];
            break;
        case WHZoomLocalShareUpdateIdle:
            self.localShareActive = NO; self.sharingComputerAudio = NO; self.requestedComputerAudio = NO; self.awaitingShareSource = NO; self.shareSourceRevision += 1;
            [self emit:@"sharing" object:@{@"active":@NO}];
            break;
        case WHZoomLocalShareUpdateUnchanged: break;
    }
    [self refreshShares];
}
- (void)onShareContentChanged:(ZoomSDKSharingSourceInfo *)info { [self onSharingStatusChanged:info]; }
- (void)onFailedToStartShare {
    BOOL audio = self.requestedComputerAudio;
    self.requestedComputerAudio = NO;
    [self emit:@"controlError" object:audio
        ? @"Zoom could not start computer audio sharing. Check the meeting’s sharing settings and allow any macOS audio capture request, then try again."
        : @"Zoom could not start sharing. Check screen recording permission and the meeting’s sharing settings."];
}
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
- (void)onLowOrRaiseHandStatusChange:(BOOL)raise UserID:(unsigned int)userID {
    NSString *session = [self.sessionID copy];
    [self onMain:^{ if (WHZoomNativeOwner == self && session && [self.sessionID isEqualToString:session] && self.hasEnteredMeeting && !self.ending) [self refreshParticipants]; }];
}
- (void)onMultiToSingleShareNeedConfirm:(ZoomSDKMultiToSingleShareConfirmHandler*_Nullable)confirmHandle { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onActiveVideoUserChanged:(unsigned int)userID { [self refreshParticipants]; }
- (void)onActiveSpeakerVideoUserChanged:(unsigned int)userID { [self refreshParticipants]; }
- (void)onHostAskUnmute { [self emit:@"controlError" object:@"The host asked you to unmute. Use the microphone control when you’re ready."]; }
- (void)onHostAskStartVideo { [self emit:@"controlError" object:@"The host asked you to start video. Use the camera control when you’re ready."]; }
- (void)onInvalidReclaimHostKey { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onHostVideoOrderUpdated:(NSArray*)orderList { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onLocalVideoOrderUpdated:(NSArray*)localOrderList { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onFollowHostVideoOrderChanged:(BOOL)follow { /* This feature is not offered by Yap. No state or permission is changed. */ }
- (void)onAllHandsLowered { [self onLowOrRaiseHandStatusChange:NO UserID:0]; }
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
- (void)publishChatFile:(ZoomSDKFileTransferInfo *)info metadata:(NSDictionary *)initial {
    if (!self.sessionID || self.ending || !info.messageId.length) return;
    if (!self.chatFileMetadata) self.chatFileMetadata = [NSMutableDictionary dictionary];
    NSMutableDictionary *metadata = [(initial ?: self.chatFileMetadata[info.messageId]) mutableCopy];
    if (!metadata) return;
    NSString *status = @"available";
    switch (info.transferStatus) {
        case ZoomSDKFileTransferStatus_Transfering: status = @"transferring"; break;
        case ZoomSDKFileTransferStatus_TransferDone: status = @"completed"; break;
        case ZoomSDKFileTransferStatus_TransferFailed: status = @"failed"; break;
        default: if ([metadata[@"isFromSelf"] boolValue]) status = @"transferring"; break;
    }
    // A cancellation callback must not turn a cancelled transfer back into Failed.
    if ([metadata[@"status"] isEqual:@"cancelled"] && info.transferStatus != ZoomSDKFileTransferStatus_TransferDone) status = @"cancelled";
    [metadata addEntriesFromDictionary:@{@"id":info.messageId, @"name":info.fileName ?: @"File", @"bytes":@(info.fileSizeBytes),
        @"date":@(info.timeStamp), @"status":status, @"progress":@(MIN(1.0, info.completePercentage / 100.0))}];
    self.chatFileMetadata[info.messageId] = metadata;
    [self emit:@"chatAttachment" object:metadata];
}
- (void)onFileSendStart:(ZoomSDKFileSender *)sender {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!session || ![self.sessionID isEqual:session] || self.ending || !sender.transferInfo.messageId.length) return;
        if (!self.chatFileSenders) self.chatFileSenders = [NSMutableDictionary dictionary];
        self.chatFileSenders[sender.transferInfo.messageId] = sender;
        ZoomSDKUserInfo *user = [[self.meeting getMeetingActionController] getUserByUserID:sender.receiverUserId];
        NSDictionary *recipient = sender.receiverUserId ? @{@"kind":@"participant", @"participantID":@(sender.receiverUserId).stringValue, @"name":[user getUserName] ?: @"Participant"} : @{@"kind":@"everyone", @"name":@"Everyone"};
        [self publishChatFile:sender.transferInfo metadata:@{@"senderName":@"You", @"recipient":recipient, @"isFromSelf":@YES}];
    }];
}
- (void)onFileReceived:(ZoomSDKFileReceiver *)receiver {
    NSString *session = [self.sessionID copy];
    [self onMain:^{
        if (!session || ![self.sessionID isEqual:session] || self.ending || !receiver.transferInfo.messageId.length) return;
        if (!self.chatFileReceivers) self.chatFileReceivers = [NSMutableDictionary dictionary];
        self.chatFileReceivers[receiver.transferInfo.messageId] = receiver;
        ZoomSDKMeetingActionController *action = [self.meeting getMeetingActionController];
        ZoomSDKUserInfo *user = [action getUserByUserID:receiver.senderUserId];
        NSDictionary *recipient = receiver.transferInfo.isSendToAll ? @{@"kind":@"everyone", @"name":@"Everyone"} :
            @{@"kind":@"participant", @"participantID":@([[action getMyself] getUserID]).stringValue, @"name":@"You"};
        [self publishChatFile:receiver.transferInfo metadata:@{@"senderName":[user getUserName] ?: @"Participant", @"recipient":recipient, @"isFromSelf":@NO}];
    }];
}
- (void)onFileTransferProgress:(ZoomSDKFileTransferInfo *)info {
    NSString *session = [self.sessionID copy];
    [self onMain:^{ if (session && [self.sessionID isEqual:session] && !self.ending) [self publishChatFile:info metadata:nil]; }];
}
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
