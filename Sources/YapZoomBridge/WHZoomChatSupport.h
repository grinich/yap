#import <Foundation/Foundation.h>
#import <ZoomSDK/ZoomSDK.h>

NSDictionary *WHZoomChatRecipient(ZoomSDKChatInfo *message, unsigned int selfID, BOOL replying);
NSArray<NSDictionary *> *WHZoomChatRuns(ZoomSDKChatInfo *message);
ZoomSDKChatInfo *WHZoomBuildChatMessage(NSDictionary *draft, ZoomSDKMeetingChatController *chat, unsigned int selfID);

ZoomSDKChatMsgInfoBuilder *WHZoomApplyChatStyles(ZoomSDKChatMsgInfoBuilder *builder, NSArray *runs, NSString *text);
