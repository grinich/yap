#import <Foundation/Foundation.h>
#import <ZoomSDK/ZoomSDK.h>
#import "WhooshZoomBridge.h"

// Real bridge, inert SDK collaborators: no SDK initialization or account access.
@interface WHZoomSDKBridge (AvatarFixture)
- (void)refreshParticipants;
- (void)onInMeetingUserAvatarPathUpdated:(unsigned int)userID;
- (void)onParticipantProfilePictureStatusChange:(BOOL)hidden;
@end

@interface AvatarUser : NSObject
@property(nonatomic, copy) NSString *path;
@end
@implementation AvatarUser
- (unsigned int)getUserID { return 7; }
- (NSString *)getUserName { return @"Fixture participant"; }
- (NSString *)getAvatarPath { return self.path; }
- (BOOL)isMySelf { return YES; }
- (BOOL)isHost { return YES; }
- (BOOL)isVideoOn { return NO; }
- (BOOL)isTalking { return NO; }
- (ZoomSDKAudioStatus)getAudioStatus { return ZoomSDKAudioStatus_Muted; }
@end

@interface AvatarAction : NSObject
@property(nonatomic, strong) AvatarUser *user;
@property(nonatomic, copy) NSArray *identifiers;
@property(nonatomic) BOOL hidden;
@property(nonatomic) NSUInteger requests;
@property(nonatomic, weak) WHZoomSDKBridge *bridge;
@end
@implementation AvatarAction
- (NSArray *)getParticipantsList { return self.identifiers; }
- (id)getUserByUserID:(unsigned int)identifier { return identifier == 7 ? self.user : nil; }
- (BOOL)isParticipantProfilePicturesHidden { return self.hidden; }
- (ZoomSDKError)requestAvatarForUser:(unsigned int)identifier {
    self.requests += 1;
    self.user.path = @"/tmp/sdk-avatar-fixture.png";
    [self.bridge onInMeetingUserAvatarPathUpdated:identifier];
    return ZoomSDKError_Success;
}
@end

@interface AvatarMeeting : NSObject
@property(nonatomic, strong) AvatarAction *action;
@end
@implementation AvatarMeeting
- (id)getMeetingActionController { return self.action; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        WHZoomSDKBridge *bridge = [WHZoomSDKBridge new];
        AvatarAction *action = [AvatarAction new];
        action.user = [AvatarUser new]; action.identifiers = @[@7]; action.hidden = YES; action.bridge = bridge;
        AvatarMeeting *meeting = [AvatarMeeting new]; meeting.action = action;
        [bridge setValue:meeting forKey:@"meeting"];
        [bridge setValue:@"inert-avatar-session" forKey:@"sessionID"];
        [bridge setValue:@YES forKey:@"hasEnteredMeeting"];
        __block NSArray *people;
        bridge.eventHandler = ^(NSString *session, NSString *event, NSData *payload) {
            if ([event isEqualToString:@"participants"]) people = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        };
        [bridge refreshParticipants];
        Check(action.requests == 0 && people.count == 1 && !people[0][@"avatarPath"], @"initial hidden policy prevents photo requests and exposure");
        action.hidden = NO;
        [bridge onParticipantProfilePictureStatusChange:NO];
        Check(action.requests == 1 && [people[0][@"avatarPath"] isEqualToString:action.user.path], @"synchronous completion survives roster emission");
        Check([people[0][@"avatarRevision"] intValue] == 1, @"completion versions the cached image");
        for (int i = 0; i < 10; i++) [bridge refreshParticipants];
        Check(action.requests == 1, @"audio and roster updates do not repeatedly download photos");
        [bridge onInMeetingUserAvatarPathUpdated:7];
        Check([people[0][@"avatarRevision"] intValue] == 2, @"same-path photo changes invalidate the image cache");
        [bridge onParticipantProfilePictureStatusChange:YES];
        Check(!people[0][@"avatarPath"], @"host hide callback takes effect even before the getter changes");
        [bridge onInMeetingUserAvatarPathUpdated:7];
        Check(!people[0][@"avatarPath"], @"late download completion cannot expose a hidden photo");
        [bridge onParticipantProfilePictureStatusChange:NO];
        Check(action.requests == 2 && people[0][@"avatarPath"] != nil, @"unhiding refreshes and restores available pictures");
        action.identifiers = @[]; [bridge refreshParticipants];
        action.identifiers = @[@7]; [bridge refreshParticipants];
        Check(action.requests == 3 && [people[0][@"avatarRevision"] intValue] == 1, @"rejoined user IDs do not inherit old request or revision state");
        puts("PASS: avatar requests, reentrant callbacks, same-path updates, host privacy and participant ID reuse");
    }
    return 0;
}
