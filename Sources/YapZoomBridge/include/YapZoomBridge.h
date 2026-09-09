#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C boundary compiled against the installed public Zoom SDK headers.
/// Events are copied to JSON data and delivered on the main thread. Never log their contents.
@interface WHZoomSDKBridge : NSObject
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *sessionID, NSString *event, NSData *payload);
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
- (NSInteger)setCloudRecordingEnabled:(BOOL)enabled NS_SWIFT_NAME(setCloudRecordingEnabled(_:));
- (NSInteger)pauseCloudRecording NS_SWIFT_NAME(pauseCloudRecording());
- (NSInteger)resumeCloudRecording NS_SWIFT_NAME(resumeCloudRecording());
- (BOOL)isWindowShareable:(uint32_t)windowID;
- (BOOL)isDesktopSharingEnabled;
- (NSInteger)startSharingWindow:(uint32_t)windowID;
- (NSInteger)startSharingDisplay:(uint32_t)displayID;
- (NSInteger)stopSharing;
- (NSInteger)admitParticipant:(uint32_t)participantID;
- (void)setVisibleParticipants:(NSArray<NSString *> *)participantIDs;
- (nullable NSView *)videoViewForParticipant:(NSString *)participantID;
- (void)selectReceivedShare:(nullable NSString *)sourceID;
- (nullable NSView *)shareViewForSource:(NSString *)sourceID;
- (NSInteger)showMeetingIndicator:(NSString *)indicatorID;
@end

NS_ASSUME_NONNULL_END
