#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C boundary compiled against the installed public Zoom SDK headers.
/// Events are copied to JSON data and delivered on the main thread. Never log their contents.
@interface WHZoomSDKBridge : NSObject
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *sessionID, NSString *event, NSData *payload);
@property(nonatomic, copy, nullable) void (^cameraEffectsChanged)(NSData *payload);
@property(nonatomic, copy, nullable) void (^mediaDevicesChanged)(NSData *payload);
@property(nonatomic, readonly, nullable) NSString *mediaDevicesError;
- (NSData *)meetingMediaSnapshot;
- (NSInteger)selectMediaDevice:(NSString *)deviceID kind:(NSString *)kind;
- (NSInteger)setMediaVolume:(NSInteger)volume kind:(NSString *)kind;
- (NSInteger)setMicrophoneAutoGain:(BOOL)enabled;
/// Microphone tests record for five seconds, then play back locally. NO cancels.
- (NSInteger)setMediaTest:(NSString *)kind running:(BOOL)running;
- (void)stopMediaTests;
- (NSInteger)setHandRaised:(BOOL)raised;
@property(nonatomic, readonly) BOOL cameraEffectsReady;
@property(nonatomic, readonly, nullable) NSString *cameraEffectsError;
/// Setters succeeded but Zoom has not yet reported the requested state.
@property(nonatomic, readonly) BOOL cameraEffectsAwaitingConfirmation;
/// Authorizes the SDK for settings only. This entry point never joins or starts capture.
- (NSInteger)prepareCameraEffectsWithJWT:(NSString *)jwt completion:(void (^)(NSInteger code, NSString * _Nullable message))completion
    NS_SWIFT_NAME(prepareCameraEffects(jwt:completion:));
- (void)setPreferredCameraBackground:(NSString *)background imagePath:(nullable NSString *)path autoFraming:(BOOL)autoFraming
    NS_SWIFT_NAME(setPreferredCameraEffects(background:imagePath:autoFraming:));
- (NSInteger)applyCameraBackground:(NSString *)background imagePath:(nullable NSString *)path autoFraming:(BOOL)autoFraming
    NS_SWIFT_NAME(applyCameraEffects(background:imagePath:autoFraming:));
/// Readback only; never starts capture or repeats a setter.
- (NSInteger)confirmCameraBackground:(NSString *)background imagePath:(nullable NSString *)path autoFraming:(BOOL)autoFraming
    NS_SWIFT_NAME(confirmCameraEffects(background:imagePath:autoFraming:));
- (NSData *)cameraEffectsSnapshot;
- (nullable NSView *)startCameraEffectsPreview;
- (void)stopCameraEffectsPreview;
- (void)closeCameraEffects;
- (NSInteger)beginRoomShareWithJWT:(NSString *)jwt sessionID:(NSString *)sessionID NS_SWIFT_NAME(beginRoomShare(jwt:sessionID:));
- (NSInteger)submitRoomSharingCode:(NSString *)code;
- (NSInteger)beginWithJWT:(NSString *)jwt zak:(NSString *)zak meetingNumber:(int64_t)meetingNumber
                vanityID:(nullable NSString *)vanityID passcode:(nullable NSString *)passcode
         registrantToken:(nullable NSString *)registrantToken displayName:(NSString *)displayName
                    host:(BOOL)host sessionID:(NSString *)sessionID
    NS_SWIFT_NAME(begin(jwt:zak:meetingNumber:vanityID:passcode:registrantToken:displayName:host:sessionID:));
- (void)leaveEndingMeeting:(BOOL)end NS_SWIFT_NAME(leave(endForEveryone:));
- (NSInteger)setMicrophoneMuted:(BOOL)muted;
- (NSInteger)setCameraEnabled:(BOOL)enabled;
- (NSInteger)sendChatText:(NSString *)text;
- (NSInteger)sendChatReply:(NSString *)text toMessage:(NSString *)messageID;
- (NSInteger)sendChatMessage:(NSData *)payload;
- (NSInteger)deleteChatMessage:(NSString *)messageID;
- (NSInteger)sendChatFile:(NSString *)path recipient:(NSData *)recipient;
- (NSInteger)receiveChatFile:(NSString *)attachmentID path:(NSString *)path;
- (NSInteger)cancelChatFile:(NSString *)attachmentID;
- (NSInteger)setCloudRecordingEnabled:(BOOL)enabled NS_SWIFT_NAME(setCloudRecordingEnabled(_:));
- (NSInteger)pauseCloudRecording NS_SWIFT_NAME(pauseCloudRecording());
- (NSInteger)resumeCloudRecording NS_SWIFT_NAME(resumeCloudRecording());
- (BOOL)isWindowShareable:(uint32_t)windowID;
- (BOOL)isDesktopSharingEnabled;
- (NSInteger)startSharingWindow:(uint32_t)windowID;
- (NSInteger)startSharingDisplay:(uint32_t)displayID;
- (BOOL)isComputerAudioSharingEnabled;
- (NSInteger)startSharingComputerAudio;
- (NSInteger)stopSharing;
- (NSInteger)preparePhotoShutter:(NSData *)pcm;
- (BOOL)isPhotoShutterReady;
- (BOOL)playPhotoShutter;
- (void)cancelPhotoShutter;
- (NSInteger)admitParticipant:(uint32_t)participantID;
- (void)setVisibleParticipants:(NSArray<NSString *> *)participantIDs;
- (nullable NSView *)videoViewForParticipant:(NSString *)participantID;
/// The active subscription reported video data; this does not acknowledge a compositor frame.
- (BOOL)isVideoReadyForCaptureForParticipant:(NSString *)participantID NS_SWIFT_NAME(isVideoReadyForCapture(forParticipant:));
- (void)selectReceivedShare:(nullable NSString *)sourceID;
- (nullable NSView *)shareViewForSource:(NSString *)sourceID;
- (NSInteger)showMeetingIndicator:(NSString *)indicatorID;
@end

NS_ASSUME_NONNULL_END
