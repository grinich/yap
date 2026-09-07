#import <Foundation/Foundation.h>
#import <ZoomSDK/ZoomSDK.h>
#import "YapZoomBridge.h"
#import <math.h>

@interface WHZoomSDKBridge (VideoDimensionsFixture)
- (void)refreshParticipants;
- (void)refreshVisibleVideoSizes;
@end

@interface DimensionsUser : NSObject
@property(nonatomic) BOOL cameraOn;
@end
@implementation DimensionsUser
- (unsigned int)getUserID { return 7; }
- (NSString *)getUserName { return @"Phone fixture"; }
- (BOOL)isMySelf { return NO; }
- (BOOL)isHost { return NO; }
- (BOOL)isVideoOn { return self.cameraOn; }
- (BOOL)isTalking { return NO; }
- (ZoomSDKAudioStatus)getAudioStatus { return ZoomSDKAudioStatus_Muted; }
@end

@interface DimensionsAction : NSObject
@property(nonatomic, strong) DimensionsUser *user;
@property(nonatomic, copy) NSArray *identifiers;
@end
@implementation DimensionsAction
- (NSArray *)getParticipantsList { return self.identifiers; }
- (id)getUserByUserID:(unsigned int)identifier { return identifier == 7 ? self.user : nil; }
- (BOOL)isParticipantProfilePicturesHidden { return YES; }
@end

@interface DimensionsMeeting : NSObject
@property(nonatomic, strong) DimensionsAction *action;
@property(nonatomic) CGSize videoSize;
@end
@implementation DimensionsMeeting
- (id)getMeetingActionController { return self.action; }
- (CGSize)getUserVideoSize:(unsigned int)identifier { return self.videoSize; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        WHZoomSDKBridge *bridge = [WHZoomSDKBridge new];
        DimensionsAction *action = [DimensionsAction new];
        action.user = [DimensionsUser new]; action.user.cameraOn = YES; action.identifiers = @[@7];
        DimensionsMeeting *meeting = [DimensionsMeeting new]; meeting.action = action;
        meeting.videoSize = CGSizeMake(720, 1280);
        [bridge setValue:meeting forKey:@"meeting"];
        [bridge setValue:@"inert-dimensions-session" forKey:@"sessionID"];
        [bridge setValue:@YES forKey:@"hasEnteredMeeting"];
        [[bridge valueForKey:@"subscribedVideos"] addObject:@"7"];
        __block NSArray *people;
        __block NSUInteger events = 0;
        bridge.eventHandler = ^(NSString *session, NSString *event, NSData *payload) {
            if ([event isEqualToString:@"participants"]) {
                people = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil]; events += 1;
            }
        };
        [bridge refreshParticipants];
        Check([people[0][@"videoWidth"] intValue] == 720 && [people[0][@"videoHeight"] intValue] == 1280, @"portrait dimensions reach the roster");
        meeting.videoSize = CGSizeMake(1280, 720); [bridge refreshVisibleVideoSizes];
        Check(events == 2 && [people[0][@"videoWidth"] intValue] == 1280, @"rotation publishes new dimensions");
        for (int i = 0; i < 10; i++) [bridge refreshVisibleVideoSizes];
        Check(events == 2, @"stable video does not flood the roster with updates");
        meeting.videoSize = CGSizeZero; [bridge refreshVisibleVideoSizes];
        Check(events == 2, @"a temporary zero size keeps the established orientation");
        meeting.videoSize = CGSizeMake(NAN, INFINITY); [bridge refreshParticipants];
        Check([people[0][@"videoWidth"] intValue] == 1280, @"invalid geometry never enters the JSON payload");
        action.user.cameraOn = NO; [bridge refreshParticipants];
        Check(!people[0][@"videoWidth"], @"camera off clears the old dimensions");
        action.user.cameraOn = YES; meeting.videoSize = CGSizeMake(720, 1280); [bridge refreshParticipants];
        action.identifiers = @[]; [bridge refreshParticipants];
        action.identifiers = @[@7]; meeting.videoSize = CGSizeZero; [bridge refreshParticipants];
        Check(!people[0][@"videoWidth"], @"reused participant IDs do not inherit old geometry");
        NSUInteger count = events;
        [[bridge valueForKey:@"subscribedVideos"] removeAllObjects];
        meeting.videoSize = CGSizeMake(1280, 720); [bridge refreshVisibleVideoSizes];
        Check(events == count, @"polling is limited to subscribed videos");
        puts("PASS: portrait dimensions, rotation, stable updates, invalid sizes, camera off and participant reuse");
    }
    return 0;
}
