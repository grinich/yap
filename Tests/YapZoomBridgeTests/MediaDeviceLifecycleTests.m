#import "CameraEffectsFixture.h"
#import <CoreAudio/CoreAudio.h>

@interface WHZoomSDKBridge (MediaFixture)
- (void)finishMediaMicrophoneRecording:(NSUUID *)token;
- (void)onLowOrRaiseHandStatusChange:(BOOL)raise UserID:(unsigned int)userID;
- (void)onAllHandsLowered;
@end

@interface MediaMicrophone : NSObject
@property(nonatomic, weak) id<ZoomSDKSettingTestAudioDelegate> delegate;
@property(nonatomic) ZoomSDKTestMicStatus status;
@property(nonatomic) NSUInteger recordings, recordingStops, plays, playbackStops;
@property(nonatomic) ZoomSDKError startResult;
@property(nonatomic) ZoomSDKError recordingStopResult, playbackStopResult;
@property(nonatomic) BOOL startupCallbacks, missingRecordingReadback, missingPlaybackReadback;
@property(nonatomic, copy) void (^onRecordingStop)(void);
@property(nonatomic, copy) void (^onDelegateSet)(void);
@property(nonatomic, copy) void (^onStarting)(void);
@property(nonatomic, copy) void (^onPlaying)(void);
@end
@implementation MediaMicrophone
@synthesize delegate = _delegate;
- (void)setDelegate:(id<ZoomSDKSettingTestAudioDelegate>)delegate {
    _delegate = delegate;
    if (delegate && self.startupCallbacks) [delegate onMicTestStatusChanged:testMic_Normal];
    if (delegate && self.onDelegateSet) self.onDelegateSet();
}
- (ZoomSDKTestMicStatus)getTestMicStatus { return self.status; }
- (ZoomSDKError)startRecordingMic:(NSString *)identifier {
    self.recordings++;
    if (self.startupCallbacks) {
        [self.delegate onMicTestStatusChanged:testMic_Normal];
        [self.delegate onMicTestStatusChanged:testMic_RecrodingStopped];
        id<ZoomSDKSettingTestAudioDelegate> delegate = self.delegate;
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [delegate onMicTestStatusChanged:testMic_Normal]; });
    }
    if (self.onStarting) self.onStarting();
    if (self.startResult == 0 && !self.missingRecordingReadback) self.status = testMic_Recording;
    if (self.startupCallbacks) [self.delegate onMicTestStatusChanged:self.status];
    return self.startResult;
}
- (ZoomSDKError)stopRecrodingMic {
    self.recordingStops++;
    if (self.recordingStopResult != 0) return self.recordingStopResult;
    self.status = testMic_RecrodingStopped;
    if (self.onRecordingStop) self.onRecordingStop();
    [self.delegate onMicTestStatusChanged:self.status]; return ZoomSDKError_Success;
}
- (ZoomSDKError)playRecordedMic {
    self.plays++;
    if (self.startupCallbacks) [self.delegate onMicTestStatusChanged:testMic_RecrodingStopped];
    if (self.onPlaying) self.onPlaying();
    if (!self.missingPlaybackReadback) self.status = testMic_Playing;
    if (self.startupCallbacks) [self.delegate onMicTestStatusChanged:self.status];
    return ZoomSDKError_Success;
}
- (ZoomSDKError)stopPlayRecordedMic {
    self.playbackStops++; if (self.playbackStopResult == 0) self.status = testMic_Normal; return self.playbackStopResult;
}
@end

@interface MediaSpeaker : NSObject
@property(nonatomic, weak) id<ZoomSDKSettingTestAudioDelegate> delegate;
@property(nonatomic) BOOL isSpeakerInTesting;
@property(nonatomic) NSUInteger starts, stops;
@property(nonatomic) ZoomSDKError result;
@property(nonatomic) ZoomSDKError stopResult;
@property(nonatomic) BOOL startupCallbacks, missingPlaybackReadback;
@property(nonatomic, copy) void (^onStarting)(void);
@end
@implementation MediaSpeaker
@synthesize delegate = _delegate;
- (void)setDelegate:(id<ZoomSDKSettingTestAudioDelegate>)delegate {
    _delegate = delegate;
    if (delegate && self.startupCallbacks) [delegate onSpeakerTestStatusChanged:NO];
}
- (ZoomSDKError)SpeakerStartPlaying:(NSString *)identifier {
    self.starts++;
    if (self.startupCallbacks) {
        [self.delegate onSpeakerTestStatusChanged:NO];
        id<ZoomSDKSettingTestAudioDelegate> delegate = self.delegate;
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [delegate onSpeakerTestStatusChanged:NO]; });
    }
    if (self.onStarting) self.onStarting();
    self.isSpeakerInTesting = self.result == 0 && !self.missingPlaybackReadback;
    if (self.startupCallbacks) [self.delegate onSpeakerTestStatusChanged:self.isSpeakerInTesting];
    return self.result;
}
- (ZoomSDKError)SpeakerStopPlaying { self.stops++; if (self.stopResult == 0) self.isSpeakerInTesting = NO; return self.stopResult; }
@end

@interface MediaAudio : NSObject
@property(nonatomic, weak) id<ZoomSDKSettingAudioDeviceDelegate> delegate;
@property(nonatomic, copy) NSArray<CameraDevice *> *microphones, *speakers;
@property(nonatomic, strong) MediaMicrophone *microphone;
@property(nonatomic, strong) MediaSpeaker *speaker;
@property(nonatomic) float micVolume, speakerVolume;
@property(nonatomic) BOOL automatic, ignoreSelection, ignoreVolume, ignoreGain;
@property(nonatomic) NSUInteger selections, volumeSets, gainSets;
@property(nonatomic) ZoomSDKError volumeResult;
@property(nonatomic) ZoomSDKError systemSelectionResult;
@property(nonatomic, copy) NSString *systemMicrophoneID, *systemSpeakerID;
@property(nonatomic) NSUInteger systemMicrophoneSelections, systemSpeakerSelections;
@end
@implementation MediaAudio
- (NSArray *)getAudioDeviceList:(BOOL)microphone { return microphone ? self.microphones : self.speakers; }
- (float)getAudioDeviceVolume:(BOOL)microphone { return microphone ? self.micVolume : self.speakerVolume; }
- (ZoomSDKError)setAudioDeviceVolume:(BOOL)microphone Volume:(float)volume {
    self.volumeSets++;
    if (self.volumeResult == 0 && !self.ignoreVolume) { if (microphone) self.micVolume = volume; else self.speakerVolume = volume; }
    return self.volumeResult;
}
- (BOOL)isAutoAdjustMicOn { return self.automatic; }
- (ZoomSDKError)enableAutoAdjustMic:(BOOL)enabled { self.gainSets++; if (!self.ignoreGain) self.automatic = enabled; return ZoomSDKError_Success; }
- (ZoomSDKError)selectAudioDevice:(BOOL)microphone DeviceID:(NSString *)identifier DeviceName:(NSString *)name {
    self.selections++;
    if (!self.ignoreSelection) for (CameraDevice *device in [self getAudioDeviceList:microphone]) device.selected = [device.identifier isEqualToString:identifier];
    return ZoomSDKError_Success;
}
- (ZoomSDKError)selectSameAudioDeviceAsSystem:(BOOL)microphone {
    if (microphone) self.systemMicrophoneSelections++; else self.systemSpeakerSelections++;
    if (self.systemSelectionResult != 0) return self.systemSelectionResult;
    NSString *identifier = microphone ? self.systemMicrophoneID : self.systemSpeakerID;
    for (CameraDevice *device in [self getAudioDeviceList:microphone]) device.selected = [device.identifier isEqualToString:identifier];
    return ZoomSDKError_Success;
}
- (id)getSettingMicrophoneTestHelper { return self.microphone; }
- (id)getSettingSpeakerTestHelper { return self.speaker; }
@end

@interface MediaSettings : CameraSettings
@property(nonatomic, strong) MediaAudio *audio;
@end
@implementation MediaSettings
- (id)getAudioSetting { return self.audio; }
@end

@interface MediaAction : CameraAction
@property(nonatomic) BOOL handRaised, cameraOn, ignoreMute;
@property(nonatomic) NSUInteger hands, commands;
@property(nonatomic) ZoomSDKError handResult;
@property(nonatomic) unsigned int lastHandUser;
@end
@implementation MediaAction
- (ZoomSDKError)actionMeetingWithCmd:(ActionMeetingCmd)command userID:(unsigned int)userID onScreen:(ScreenType)screen {
    self.commands++;
    if (command == ActionMeetingCmd_MuteVideo && !self.ignoreMute) self.cameraOn = NO;
    if (command == ActionMeetingCmd_UnMuteVideo) self.cameraOn = YES;
    return [super actionMeetingWithCmd:command userID:userID onScreen:screen];
}
- (ZoomSDKError)raiseHand:(BOOL)raised UserID:(unsigned int)userID {
    self.hands++; self.lastHandUser = userID;
    if (self.handResult == 0) self.handRaised = raised;
    return self.handResult;
}
- (NSArray *)getParticipantsList { return @[@42]; }
- (id)getUserByUserID:(unsigned int)userID { return userID == 42 ? self : nil; }
- (BOOL)isParticipantProfilePicturesHidden { return YES; }
- (unsigned int)getUserID { return 42; }
- (NSString *)getUserName { return @"Fixture participant"; }
- (BOOL)isMySelf { return YES; }
- (BOOL)isHost { return YES; }
- (BOOL)isH323User { return NO; }
- (BOOL)isVideoOn { return self.cameraOn; }
- (BOOL)isTalking { return NO; }
- (BOOL)isRaisingHand { return self.handRaised; }
- (ZoomSDKAudioStatus)getAudioStatus { return ZoomSDKAudioStatus_Muted; }
@end

@interface MediaBridge : CameraGateBridge
@end
@implementation MediaBridge
- (NSValue *)videoSizeForUser:(unsigned int)userID cameraEnabled:(BOOL)enabled { return nil; }
- (void)refreshChatPolicy {}
@end

static NSDictionary *Snapshot(WHZoomSDKBridge *bridge) {
    return [NSJSONSerialization JSONObjectWithData:[bridge meetingMediaSnapshot] options:0 error:nil];
}
static void CheckBooleanSnapshot(NSDictionary *snapshot) {
    for (NSString *key in @[@"isReady", @"isInMeeting", @"automaticMicrophoneVolume", @"canSetMicrophoneVolume", @"canSetSpeakerVolume", @"speakerTestRunning"]) {
        id value = snapshot[key];
        Check(value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(),
              [NSString stringWithFormat:@"media snapshot %@ serializes as a JSON boolean, not a numeric flag", key]);
    }
    for (NSString *key in @[@"microphones", @"speakers", @"cameras"]) for (NSDictionary *device in snapshot[key]) {
        id value = device[@"selected"];
        Check(value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(),
              @"device selection serializes as a JSON boolean");
    }
}
static CameraDevice *Device(NSString *identifier, BOOL selected) {
    CameraDevice *device = [CameraDevice new]; device.identifier = identifier; device.selected = selected; return device;
}

static void SystemDeviceChanged(AudioObjectPropertyListenerBlock listener, BOOL microphone) {
    AudioObjectPropertyAddress address = { microphone ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    listener(1, &address);
}

int main(void) {
    @autoreleasepool {
        MediaSettings *settings = [MediaSettings new];
        settings.background = [CameraBackground new]; settings.video = [CameraVideoSetting new];
        settings.audio = [MediaAudio new];
        MediaAudio *audio = settings.audio;
        audio.microphone = [MediaMicrophone new]; audio.speaker = [MediaSpeaker new];
        audio.microphone.startupCallbacks = YES; audio.speaker.startupCallbacks = YES;
        audio.microphones = @[Device(@"mic-a", YES), Device(@"mic-b", NO), Device(@"", NO)];
        audio.speakers = @[Device(@"speaker-a", YES), Device(@"speaker-b", NO)];
        audio.systemMicrophoneID = @"mic-a"; audio.systemSpeakerID = @"speaker-a";
        audio.micVolume = 0; audio.speakerVolume = 75;
        settings.video.cameras = @[Device(@"camera-a", YES), Device(@"camera-b", NO)];
        fixtureSDK = [CameraSDK new]; fixtureSDK.settings = settings; fixtureSDK.auth = [CameraAuth new];
        fixtureSDK.meeting = [CameraMeeting new]; fixtureSDK.meeting.container = [CameraContainer new];
        MediaAction *action = [MediaAction new]; action.operations = [NSMutableArray array]; fixtureSDK.meeting.action = action;
        Method shared = class_getClassMethod(ZoomSDK.class, @selector(sharedSDK));
        IMP originalShared = method_setImplementation(shared, (IMP)FixtureSharedSDK);
        Method authorization = class_getClassMethod(AVCaptureDevice.class, @selector(authorizationStatusForMediaType:));
        IMP originalAuthorization = method_setImplementation(authorization, (IMP)FixtureCameraAuthorization);
        MediaBridge *bridge = [MediaBridge new]; bridge.operations = [NSMutableArray array];
        NSString *preferenceSuite = [@"app.yap.tests.audio." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:preferenceSuite];
        [bridge setValue:preferences forKey:@"mediaDevicePreferences"];
        CheckBooleanSnapshot(Snapshot(bridge));
        __block NSDictionary *lastSnapshot;
        __block NSUInteger snapshots = 0;
        bridge.mediaDevicesChanged = ^(NSData *data) {
            lastSnapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            CheckBooleanSnapshot(lastSnapshot); snapshots++;
        };
        Check(![Snapshot(bridge)[@"isReady"] boolValue] && [bridge setMediaVolume:10 kind:@"microphone"] != 0,
              @"uninitialized media controls remain unavailable without touching SDK devices");
        Check([bridge prepareCameraEffectsWithJWT:@"inert-media-auth" completion:^(NSInteger result, NSString *message) {
            Check(result == 0, @"settings-only media authorization succeeds in the fixture");
        }] == 0, @"settings-only media acquires the inert SDK");
        [bridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        Check([lastSnapshot[@"isReady"] boolValue] && ![lastSnapshot[@"isInMeeting"] boolValue] &&
              [lastSnapshot[@"microphones"] count] == 3 && [lastSnapshot[@"microphoneVolume"] integerValue] == 0 &&
              fixtureSDK.meeting.joins == 0 && action.commands == 0 && audio.microphone.recordings == 0 && audio.speaker.starts == 0,
              @"authorization publishes real SDK device choices and a valid zero gain without joining or testing media");
        Check(audio.systemMicrophoneSelections == 1 && audio.systemSpeakerSelections == 1 &&
              [lastSnapshot[@"microphones"][0][@"id"] isEqual:@"yap.system-default"] &&
              [lastSnapshot[@"microphones"][0][@"selected"] boolValue] && ![lastSnapshot[@"microphones"][1][@"selected"] boolValue] &&
              [lastSnapshot[@"speakers"][0][@"selected"] boolValue],
              @"fresh audio settings follow macOS independently and expose exactly one selected menu choice per channel");
        AudioObjectPropertyListenerBlock systemListener = [bridge valueForKey:@"systemAudioDeviceListener"];
        Check(systemListener != nil && [[bridge valueForKey:@"observesSystemMicrophone"] boolValue] &&
              [[bridge valueForKey:@"observesSystemSpeaker"] boolValue], @"both macOS default device listeners are installed");
        Check([bridge selectMediaDevice:@"missing" kind:@"microphone"] != 0 && audio.selections == 0,
              @"unknown device identifiers never reach SDK selection");
        audio.ignoreSelection = YES;
        Check([bridge selectMediaDevice:@"mic-b" kind:@"microphone"] != 0 && audio.microphones[0].selected &&
              [Snapshot(bridge)[@"microphones"][0][@"selected"] boolValue] &&
              [preferences stringForKey:@"audio.microphoneDeviceID"] == nil,
              @"an unconfirmed hardware selection cannot silently disable or overwrite system following");
        audio.ignoreSelection = NO;
        Check([bridge selectMediaDevice:@"mic-b" kind:@"microphone"] == 0 && audio.microphones[1].selected,
              @"device selection resolves identifiers and verifies the SDK selected-device getter");
        audio.ignoreSelection = YES;
        Check([bridge selectMediaDevice:@"mic-a" kind:@"microphone"] != 0 && audio.microphones[1].selected,
              @"setter success with stale device readback does not claim selection succeeded");
        audio.ignoreSelection = NO;
        [bridge setValue:@"audio-switch-fixture" forKey:@"sessionID"]; [bridge setValue:@YES forKey:@"hasEnteredMeeting"];
        NSUInteger systemMicrophoneSelections = audio.systemMicrophoneSelections;
        SystemDeviceChanged(systemListener, YES);
        Check(audio.microphones[1].selected && audio.systemMicrophoneSelections == systemMicrophoneSelections &&
              [preferences stringForKey:@"audio.microphoneDeviceID"] != nil,
              @"an explicit microphone stays pinned through macOS input changes during a call");
        audio.systemSpeakerID = @"speaker-b";
        SystemDeviceChanged(systemListener, NO);
        Check(audio.speakers[1].selected && audio.systemSpeakerSelections == 2 && audio.microphones[1].selected &&
              [Snapshot(bridge)[@"speakers"][0][@"selected"] boolValue] && action.commands == 0,
              @"a macOS output change switches the running SDK without rejoining, unmuting, or changing the pinned microphone");
        Check([bridge selectMediaDevice:@"yap.system-default" kind:@"microphone"] == 0 && audio.microphones[0].selected &&
              [[preferences stringForKey:@"audio.microphoneDeviceID"] isEqual:@"yap.system-default"],
              @"Same as System restores input following and persists that preference");
        audio.systemMicrophoneID = @"mic-b";
        SystemDeviceChanged(systemListener, YES);
        Check(audio.microphones[1].selected && audio.systemMicrophoneSelections == systemMicrophoneSelections + 2 &&
              [Snapshot(bridge)[@"microphones"][0][@"selected"] boolValue] && action.commands == 0,
              @"a macOS input change reaches the running SDK while preserving the muted call state");
        NSUInteger pinnedSelections = audio.selections;
        Check([bridge selectMediaDevice:@"mic-b" kind:@"microphone"] == 0 && audio.selections == pinnedSelections + 1 &&
              ![Snapshot(bridge)[@"microphones"][0][@"selected"] boolValue],
              @"pinning the currently active physical device exits following mode instead of taking the old no-op path");
        [preferences removeObjectForKey:@"audio.microphoneDeviceID"];
        Check([bridge selectMediaDevice:@"mic-b" kind:@"microphone"] == 0 &&
              [[preferences stringForKey:@"audio.microphoneDeviceID"] isEqual:@"mic-b"],
              @"an already-selected physical device still persists the explicit user choice");
        audio.systemMicrophoneID = @"mic-a";
        SystemDeviceChanged(systemListener, YES);
        Check(audio.microphones[1].selected, @"later system changes cannot override the pinned current microphone");
        audio.systemSelectionResult = ZoomSDKError_ServiceFailed;
        Check([bridge selectMediaDevice:@"yap.system-default" kind:@"microphone"] != 0 &&
              ![Snapshot(bridge)[@"microphones"][0][@"selected"] boolValue] &&
              [[preferences stringForKey:@"audio.microphoneDeviceID"] isEqual:@"mic-b"],
              @"a failed default-device selection does not claim following mode or overwrite the saved hardware choice");
        audio.systemSelectionResult = ZoomSDKError_Success;
        [bridge setValue:nil forKey:@"sessionID"]; [bridge setValue:@NO forKey:@"hasEnteredMeeting"];
        Check([bridge setMediaVolume:-1 kind:@"speaker"] != 0 && [bridge setMediaVolume:101 kind:@"speaker"] != 0 && audio.volumeSets == 0,
              @"volume range validation prevents out-of-range SDK writes");
        Check([bridge setMicrophoneAutoGain:YES] == 0 && ![Snapshot(bridge)[@"canSetMicrophoneVolume"] boolValue] &&
              [bridge setMediaVolume:50 kind:@"microphone"] != 0 && audio.volumeSets == 0,
              @"automatic gain disables manual microphone gain without silently changing automatic gain");
        Check([bridge setMicrophoneAutoGain:NO] == 0 && [bridge setMediaVolume:50 kind:@"microphone"] == 0 && audio.micVolume == 50,
              @"manual microphone gain writes the public SDK volume scale");
        audio.volumeResult = ZoomSDKError_UnSupportedFeature;
        Check([bridge setMediaVolume:20 kind:@"speaker"] == ZoomSDKError_UnSupportedFeature && bridge.mediaDevicesError.length > 0 && audio.speakerVolume == 75,
              @"hardware volume errors propagate without inventing a changed volume");
        audio.volumeResult = ZoomSDKError_Success;
        audio.ignoreVolume = YES;
        Check([bridge setMediaVolume:20 kind:@"speaker"] == ZoomSDKError_ServiceFailed && audio.speakerVolume == 75,
              @"success without the requested volume readback remains a reported failure");
        audio.ignoreVolume = NO; audio.ignoreGain = YES;
        Check([bridge setMicrophoneAutoGain:YES] == ZoomSDKError_ServiceFailed && !audio.automatic,
              @"success without automatic-gain readback cannot claim that setting changed");
        audio.ignoreGain = NO; audio.micVolume = 49.6;
        Check([Snapshot(bridge)[@"microphoneVolume"] isEqual:@50], @"fractional hardware volume becomes a decodable integer percentage");

        fixtureCameraAuthorization = AVAuthorizationStatusDenied;
        Check([bridge setMediaTest:@"microphone" running:YES] == ZoomSDKError_NoPermission && audio.microphone.recordings == 0,
              @"microphone permission is required before explicit recording tests");
        fixtureCameraAuthorization = AVAuthorizationStatusAuthorized;
        Check([bridge setMediaTest:@"speaker" running:YES] == 0 && audio.speaker.starts == 1 && [Snapshot(bridge)[@"speakerTestRunning"] boolValue],
              @"an explicit speaker test only invokes local SDK playback");
        DrainMainQueue();
        Check([Snapshot(bridge)[@"speakerTestRunning"] boolValue],
              @"synchronous and queued initial false callbacks cannot complete a just-started speaker test");
        Check([bridge setMediaTest:@"microphone" running:YES] == 0 && audio.speaker.stops == 1 && audio.microphone.recordings == 1,
              @"starting a microphone test stops competing speaker playback");
        DrainMainQueue();
        Check([Snapshot(bridge)[@"microphoneTest"] isEqual:@"recording"] && audio.microphone.plays == 0,
              @"initial Normal and RecordingStopped callbacks cannot clear recording or prematurely start playback");
        NSUUID *recording = [bridge valueForKey:@"mediaMicrophoneTestToken"];
        [bridge finishMediaMicrophoneRecording:recording];
        Check(audio.microphone.recordingStops == 1 && audio.microphone.plays == 1 && [Snapshot(bridge)[@"microphoneTest"] isEqual:@"playing"],
              @"the bounded recording transitions through stop to local playback exactly once even with synchronous callbacks");
        id<ZoomSDKSettingTestAudioDelegate> oldTestObserver = audio.microphone.delegate;
        Check([bridge setMediaTest:@"microphone" running:NO] == 0 && audio.microphone.playbackStops == 1,
              @"cancelling the microphone test stops playback and releases its callback identity");
        [oldTestObserver onMicTestStatusChanged:testMic_RecrodingStopped];
        [bridge finishMediaMicrophoneRecording:recording];
        Check(audio.microphone.plays == 1 && [Snapshot(bridge)[@"microphoneTest"] isEqual:@"idle"],
              @"late recording callbacks and timers cannot play a cancelled recording");
        Check([bridge setMediaTest:@"microphone" running:YES] == 0, @"a second explicit microphone test starts");
        NSUInteger stops = audio.microphone.recordingStops;
        [audio.delegate onMicDeviceStatusChanged:Audio_No_Input];
        [audio.delegate onMicDeviceStatusChanged:Audio_Error_Be_Muted];
        [audio.delegate onMicDeviceStatusChanged:Device_List_Update];
        [audio.delegate onSelectedMicDeviceChanged];
        Check(audio.microphone.recordingStops == stops && [Snapshot(bridge)[@"microphoneTest"] isEqual:@"recording"],
              @"muted, silent, and unchanged selected-device notifications cannot silently cancel a microphone test");
        audio.microphones[0].selected = YES; audio.microphones[1].selected = NO;
        [audio.delegate onMicDeviceStatusChanged:Device_List_Update];
        Check(audio.microphone.recordingStops == stops + 1 && [Snapshot(bridge)[@"microphoneTest"] isEqual:@"idle"],
              @"hotplug stops the affected test and publishes fresh devices");
        Check(action.commands == 0, @"audio settings and tests never join audio, unmute, or send camera commands");

        Check([bridge setMediaTest:@"microphone" running:YES] == 0, @"a microphone stop-failure fixture starts explicitly");
        oldTestObserver = audio.microphone.delegate;
        audio.microphone.recordingStopResult = ZoomSDKError_ServiceFailed;
        audio.microphone.playbackStopResult = ZoomSDKError_ServiceFailed;
        Check([bridge setMediaTest:@"microphone" running:NO] != 0 &&
              [Snapshot(bridge)[@"microphoneTest"] isEqual:@"stoppingFailed"] &&
              [bridge valueForKey:@"mediaMicrophoneHelper"] == audio.microphone && bridge.mediaDevicesError.length > 0,
              @"a failed microphone stop retains a retryable handle and never falsely publishes idle");
        NSUInteger blockedStarts = audio.speaker.starts, blockedSelections = audio.selections;
        Check([bridge setMediaTest:@"speaker" running:YES] != 0 && audio.speaker.starts == blockedStarts &&
              [bridge selectMediaDevice:@"mic-a" kind:@"microphone"] != 0 && audio.selections == blockedSelections,
              @"unconfirmed microphone stop blocks another test and device selection");
        NSUInteger playsBeforeFailedStopCallback = audio.microphone.plays;
        [oldTestObserver onMicTestStatusChanged:testMic_RecrodingStopped];
        Check(audio.microphone.plays == playsBeforeFailedStopCallback, @"failed-stop retention never revives the old playback callback");
        audio.microphone.recordingStopResult = ZoomSDKError_Success; audio.microphone.playbackStopResult = ZoomSDKError_Success;
        Check([bridge setMediaTest:@"microphone" running:NO] == 0 && [Snapshot(bridge)[@"microphoneTest"] isEqual:@"idle"] &&
              [bridge valueForKey:@"mediaMicrophoneHelper"] == nil,
              @"a later successful Stop retries the retained microphone and clears active state");

        Check([bridge setMediaTest:@"speaker" running:YES] == 0, @"a speaker stop-failure fixture starts explicitly");
        audio.speaker.stopResult = ZoomSDKError_ServiceFailed;
        Check([bridge setMediaTest:@"speaker" running:NO] != 0 && [Snapshot(bridge)[@"speakerTestRunning"] boolValue] &&
              [bridge valueForKey:@"mediaSpeakerHelper"] == audio.speaker,
              @"failed speaker stop preserves its handle and active snapshot");
        blockedStarts = audio.microphone.recordings;
        Check([bridge setMediaTest:@"microphone" running:YES] != 0 && audio.microphone.recordings == blockedStarts,
              @"unconfirmed speaker stop cannot start microphone recording");
        audio.speaker.stopResult = ZoomSDKError_Success;
        [bridge stopMediaTests];
        Check(![Snapshot(bridge)[@"speakerTestRunning"] boolValue] && bridge.mediaDevicesError == nil,
              @"global Stop retries retained speaker playback and clears its error only after success");
        Check([bridge setMediaTest:@"speaker" running:YES] == 0, @"a naturally completed speaker fixture starts explicitly");
        NSUInteger naturalCompletionStops = audio.speaker.stops;
        audio.speaker.isSpeakerInTesting = NO;
        [audio.speaker.delegate onSpeakerTestStatusChanged:NO];
        Check(![Snapshot(bridge)[@"speakerTestRunning"] boolValue] && audio.speaker.stops == naturalCompletionStops,
              @"confirmed natural playback completion clears state without a redundant SDK Stop");

        audio.microphone.missingRecordingReadback = YES;
        Check([bridge setMediaTest:@"microphone" running:YES] == ZoomSDKError_ServiceFailed &&
              [Snapshot(bridge)[@"microphoneTest"] isEqual:@"idle"] && bridge.mediaDevicesError.length > 0,
              @"the SDK wrapper's unconditional success cannot hide a failed recording start getter");
        audio.microphone.missingRecordingReadback = NO;
        audio.speaker.missingPlaybackReadback = YES;
        Check([bridge setMediaTest:@"speaker" running:YES] == ZoomSDKError_ServiceFailed &&
              ![Snapshot(bridge)[@"speakerTestRunning"] boolValue] && bridge.mediaDevicesError.length > 0,
              @"speaker start also requires confirmed playback readback");
        audio.speaker.missingPlaybackReadback = NO;
        audio.microphone.missingPlaybackReadback = YES;
        Check([bridge setMediaTest:@"microphone" running:YES] == 0, @"a failed microphone-playback fixture records first");
        [bridge finishMediaMicrophoneRecording:[bridge valueForKey:@"mediaMicrophoneTestToken"]];
        Check([Snapshot(bridge)[@"microphoneTest"] isEqual:@"idle"] && [Snapshot(bridge)[@"error"] isKindOfClass:NSString.class],
              @"microphone playback setter success with failed readback publishes an asynchronous error");
        audio.microphone.missingPlaybackReadback = NO;
        __weak MediaBridge *weakBridge = bridge;
        audio.microphone.onDelegateSet = ^{ [weakBridge stopMediaTests]; };
        NSUInteger startsBeforeDelegateCancellation = audio.microphone.recordings;
        Check([bridge setMediaTest:@"microphone" running:YES] == ZoomSDKError_WrongUsage && audio.microphone.recordings == startsBeforeDelegateCancellation,
              @"cancellation during delegate attachment blocks the subsequent recording call");
        audio.microphone.onDelegateSet = nil;
        audio.microphone.onStarting = ^{ [weakBridge stopMediaTests]; };
        NSUInteger stopsBeforeReentrantStart = audio.microphone.recordingStops;
        Check([bridge setMediaTest:@"microphone" running:YES] == ZoomSDKError_WrongUsage &&
              audio.microphone.recordingStops == stopsBeforeReentrantStart + 2 && audio.microphone.status == testMic_Normal &&
              [bridge valueForKey:@"mediaMicrophoneHelper"] == nil,
              @"a recording that finishes starting after synchronous Stop gets a second cleanup Stop");
        audio.microphone.onStarting = nil;
        audio.speaker.onStarting = ^{ [weakBridge stopMediaTests]; };
        stopsBeforeReentrantStart = audio.speaker.stops;
        Check([bridge setMediaTest:@"speaker" running:YES] == ZoomSDKError_WrongUsage &&
              audio.speaker.stops == stopsBeforeReentrantStart + 2 && !audio.speaker.isSpeakerInTesting,
              @"speaker capture completing after synchronous Stop also receives final cleanup");
        audio.speaker.onStarting = nil;
        audio.microphone.onPlaying = ^{ [weakBridge stopMediaTests]; };
        Check([bridge setMediaTest:@"microphone" running:YES] == 0, @"a reentrant playback cancellation fixture records first");
        NSUInteger playbackStopsBeforeReentrancy = audio.microphone.playbackStops;
        [bridge finishMediaMicrophoneRecording:[bridge valueForKey:@"mediaMicrophoneTestToken"]];
        Check(audio.microphone.playbackStops == playbackStopsBeforeReentrancy + 2 && audio.microphone.status == testMic_Normal &&
              [Snapshot(bridge)[@"microphoneTest"] isEqual:@"idle"],
              @"playback that starts after a synchronous cancellation receives a second cleanup Stop");
        audio.microphone.onPlaying = nil;

        [bridge setValue:@NO forKey:@"cameraSettingsOnly"]; [bridge setValue:@"inert-meeting" forKey:@"sessionID"];
        [bridge setValue:@YES forKey:@"hasEnteredMeeting"];
        __block NSArray *participants;
        bridge.eventHandler = ^(NSString *session, NSString *event, NSData *data) {
            if ([event isEqual:@"participants"]) participants = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        };
        Check([bridge setHandRaised:YES] == 0 && action.lastHandUser == 42 && [participants[0][@"handRaised"] boolValue],
              @"raising a hand targets the current self and publishes confirmed participant state");
        action.handResult = ZoomSDKError_NoPermission;
        Check([bridge setHandRaised:NO] == ZoomSDKError_NoPermission && [participants[0][@"handRaised"] boolValue],
              @"SDK hand restrictions propagate without falsely lowering the participant hand");
        action.handRaised = NO;
        [bridge onAllHandsLowered];
        Check(![participants[0][@"handRaised"] boolValue], @"host hand changes refresh the participant getter");

        action.cameraOn = YES; bridge.applyResult = ZoomSDKError_ServiceFailed;
        Check([bridge selectMediaDevice:@"camera-b" kind:@"camera"] != 0 && !action.cameraOn && action.mutes == 1 && action.unmutes == 0,
              @"switching a live camera mutes first and effect failure keeps the new camera off");
        bridge.applyResult = ZoomSDKError_Success; action.cameraOn = YES;
        Check([bridge selectMediaDevice:@"camera-a" kind:@"camera"] == 0 && action.cameraOn && action.mutes == 2 && action.unmutes == 1,
              @"camera switching resumes sending only through the saved-effect gate after confirmed selection");
        action.ignoreMute = YES;
        NSUInteger cameraSelections = settings.video.selections;
        Check([bridge selectMediaDevice:@"camera-b" kind:@"camera"] != 0 && settings.video.selections == cameraSelections,
              @"a mute setter with camera-still-on readback cannot expose a newly selected camera");
        action.ignoreMute = NO;

        Check([bridge setMediaTest:@"microphone" running:YES] == 0, @"a final local recording starts explicitly");
        oldTestObserver = audio.microphone.delegate;
        id<ZoomSDKSettingAudioDeviceDelegate> oldDeviceObserver = audio.delegate;
        [bridge setValue:nil forKey:@"sessionID"]; [bridge setValue:@YES forKey:@"cameraSettingsOnly"];
        [bridge closeCameraEffects];
        Check(![lastSnapshot[@"isReady"] boolValue] && [lastSnapshot[@"microphones"] count] == 0 && audio.microphone.status == testMic_Normal,
              @"settings close stops recording and publishes an unavailable empty device snapshot");
        NSUInteger snapshotsAfterClose = snapshots, playsAfterClose = audio.microphone.plays;
        NSUInteger selectionsAfterClose = audio.systemSpeakerSelections;
        Check([bridge valueForKey:@"systemAudioDeviceListener"] == nil && ![[bridge valueForKey:@"observesSystemSpeaker"] boolValue],
              @"teardown removes macOS audio listeners before releasing the SDK");
        SystemDeviceChanged(systemListener, NO);
        Check(audio.systemSpeakerSelections == selectionsAfterClose && snapshots == snapshotsAfterClose,
              @"a queued macOS callback cannot use a closed SDK");
        [oldTestObserver onMicTestStatusChanged:testMic_RecrodingStopped];
        [oldDeviceObserver onSelectedMicDeviceChanged];
        Check(snapshots == snapshotsAfterClose && audio.microphone.plays == playsAfterClose && [bridge setHandRaised:YES] != 0,
              @"callbacks retained by a closed SDK cannot publish stale devices, replay recordings, or raise a hand");
        audio.microphones[0].selected = YES; audio.microphones[1].selected = NO;
        Check([bridge prepareCameraEffectsWithJWT:@"inert-media-reauth" completion:^(NSInteger result, NSString *message) {
            Check(result == 0, @"a new settings generation authorizes independently");
        }] == 0, @"media settings can reopen after cleanup");
        [bridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        Check(audio.microphones[1].selected && ![Snapshot(bridge)[@"microphones"][0][@"selected"] boolValue] &&
              [Snapshot(bridge)[@"speakers"][0][@"selected"] boolValue],
              @"a recreated SDK restores the fixed input preference and default output independently");
        NSUInteger snapshotsAfterReopen = snapshots;
        selectionsAfterClose = audio.systemSpeakerSelections;
        SystemDeviceChanged(systemListener, NO);
        Check(audio.systemSpeakerSelections == selectionsAfterClose && snapshots == snapshotsAfterReopen,
              @"a callback from the previous authorization cannot change devices in the new SDK generation");
        [oldTestObserver onMicTestStatusChanged:testMic_RecrodingStopped];
        [oldDeviceObserver onSelectedMicDeviceChanged];
        Check(snapshots == snapshotsAfterReopen && audio.microphone.plays == playsAfterClose,
              @"old SDK observer generations remain inert even after the same bridge becomes ready again");
        [bridge closeCameraEffects];

        audio.microphones = @[Device(@"mic-a", YES)];
        Check([bridge prepareCameraEffectsWithJWT:@"inert-unplugged-media-auth" completion:^(NSInteger result, NSString *message) {
            Check(result == 0, @"unplugged-device fixture authorizes");
        }] == 0, @"settings can reopen after the preferred microphone is unplugged");
        [bridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        Check([Snapshot(bridge)[@"microphones"][0][@"selected"] boolValue] &&
              [[preferences stringForKey:@"audio.microphoneDeviceID"] isEqual:@"mic-b"],
              @"an unavailable preferred microphone falls back to macOS without erasing the saved preference");
        AudioObjectPropertyListenerBlock currentSystemListener = [bridge valueForKey:@"systemAudioDeviceListener"];
        audio.systemSelectionResult = ZoomSDKError_ServiceFailed;
        SystemDeviceChanged(currentSystemListener, NO);
        Check(bridge.mediaDevicesError.length > 0, @"an asynchronous default-device failure is visible in the audio menu");
        audio.systemSelectionResult = ZoomSDKError_Success;
        SystemDeviceChanged(currentSystemListener, NO);
        Check(bridge.mediaDevicesError == nil, @"a later successful system device update clears its previous failure");
        Check([bridge setMediaTest:@"microphone" running:YES] == 0, @"system-switch cancellation fixture starts a local test");
        audio.microphone.onRecordingStop = ^{ [weakBridge closeCameraEffects]; };
        systemMicrophoneSelections = audio.systemMicrophoneSelections;
        SystemDeviceChanged(currentSystemListener, YES);
        Check(![Snapshot(bridge)[@"isReady"] boolValue] && audio.systemMicrophoneSelections == systemMicrophoneSelections,
              @"teardown reentered while stopping a test prevents the subsequent default-device SDK call");
        audio.microphone.onRecordingStop = nil;
        [preferences removePersistentDomainForName:preferenceSuite];
        method_setImplementation(authorization, originalAuthorization); method_setImplementation(shared, originalShared);
        puts("PASS: inert media devices, local audio test lifecycle, camera-switch effect gate, and raise-hand readback");
    }
    return 0;
}
