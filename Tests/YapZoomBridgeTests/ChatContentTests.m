#import <Foundation/Foundation.h>
#import "WHZoomChatSupport.h"
#import "YapZoomBridge.h"

@interface WHZoomSDKBridge (ChatFixture)
- (NSDictionary *)chatPolicySnapshot;
@end

static void Check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

@interface ChatAudienceFixture : NSObject
@property(nonatomic) ZoomSDKChatMessageType type;
@property(nonatomic) unsigned int senderID;
@property(nonatomic) unsigned int receiverID;
@end
@implementation ChatAudienceFixture
- (ZoomSDKChatMessageType)getChatMessageType { return self.type; }
- (BOOL)isChatToWaitingRoom { return self.type == ZoomSDKChatMessageType_To_WaitingRoomUsers; }
- (unsigned int)getSenderUserID { return self.senderID; }
- (unsigned int)getReceiverUserID { return self.receiverID; }
- (NSString *)getSenderDisplayName { return @"Alex"; }
- (NSString *)getReceiverDisplayName { return @"Me"; }
@end

@interface ChatStyleSpy : NSObject
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *calls;
@end
@implementation ChatStyleSpy
- (instancetype)init { if ((self = [super init])) self.calls = [NSMutableArray array]; return self; }
- (id)setBold:(unsigned int)start positionEnd:(unsigned int)end {
    [self.calls addObject:@{@"style":@"bold", @"start":@(start), @"end":@(end)}]; return self;
}
- (id)setItalic:(unsigned int)start positionEnd:(unsigned int)end {
    [self.calls addObject:@{@"style":@"italic", @"start":@(start), @"end":@(end)}]; return self;
}
@end

int main(void) {
    @autoreleasepool {
        ChatAudienceFixture *fixture = [ChatAudienceFixture new]; fixture.senderID = 2; fixture.receiverID = 1;
        fixture.type = ZoomSDKChatMessageType_To_Individual;
        NSDictionary *received = WHZoomChatRecipient((id)fixture, 1, NO);
        NSDictionary *reply = WHZoomChatRecipient((id)fixture, 1, YES);
        Check([received[@"participantID"] isEqual:@"1"] && [reply[@"participantID"] isEqual:@"2"], "private reply targets sender");
        fixture.type = ZoomSDKChatMessageType_To_Individual_Panelist;
        Check([WHZoomChatRecipient((id)fixture, 1, NO)[@"kind"] isEqual:@"attendeeAndPanelists"], "attendee plus panelists is not private");
        fixture.type = ZoomSDKChatMessageType_To_None;
        Check([WHZoomChatRecipient((id)fixture, 1, YES)[@"kind"] isEqual:@"unavailable"], "unknown audience cannot become public");
        fixture.type = ZoomSDKChatMessageType_To_WaitingRoomUsers;
        Check([WHZoomChatRecipient((id)fixture, 1, YES)[@"kind"] isEqual:@"waitingRoom"], "waiting room audience preserved");

        // This only builds and reads a message object. It never initializes a
        // meeting, opens media, authenticates, or calls sendChatMsgTo.
        NSDictionary *draft = @{@"text":@"A🙂BC", @"recipient":@{@"kind":@"everyone", @"name":@"Everyone"},
            @"runs":@[@{@"text":@"A🙂", @"bold":@YES}, @{@"text":@"BC", @"italic":@YES}]};
        ZoomSDKChatInfo *message = WHZoomBuildChatMessage(draft, nil, 1);
        Check(message != nil, "offline SDK rich-text builder returns a message");
        Check([[message getMsgContent] isEqual:@"A🙂BC"], "native builder preserves emoji text");
        // The offline SDK builder does not populate received-message segment
        // getters. A spy verifies the actual style calls/ranges instead; live
        // interoperability remains separate from this local contract test.
        ChatStyleSpy *spy = [ChatStyleSpy new];
        Check(WHZoomApplyChatStyles((id)spy, draft[@"runs"], draft[@"text"]) != nil, "native style application accepts consistent segments");
        Check(spy.calls.count == 2, "each formatted segment receives one style call");
        Check([spy.calls[0] isEqual:@{@"style":@"bold", @"start":@0, @"end":@3}], "bold emoji range uses NSString UTF-16 length");
        Check([spy.calls[1] isEqual:@{@"style":@"italic", @"start":@3, @"end":@5}], "next style begins at preceding UTF-16 end");
        Check(WHZoomApplyChatStyles((id)spy, @[@{@"text":@"Mismatch"}], @"Actual") == nil, "mismatched native formatting is rejected");
        Check(WHZoomBuildChatMessage(@{@"text":@"No", @"recipient":@{@"kind":@"participant", @"participantID":@"0"}}, nil, 1) == nil, "zero private recipient is rejected");
        WHZoomSDKBridge *bridge = [WHZoomSDKBridge new];
        NSData *json = [NSJSONSerialization dataWithJSONObject:[bridge chatPolicySnapshot] options:0 error:nil];
        NSDictionary *policy = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        for (NSString *key in @[@"canEveryone", @"canPrivate", @"onlyHost", @"canWaitingRoom", @"canPanelists", @"canTransferFiles"]) {
            Check(CFGetTypeID((__bridge CFTypeRef)policy[key]) == CFBooleanGetTypeID(), "chat policy fields survive JSON as booleans, not numeric zero/one");
        }
        puts("PASS: native chat audiences, unknown routing, private recipient validation, UTF-16 style calls, offline content builder, and JSON policy booleans");
    }
    return 0;
}
