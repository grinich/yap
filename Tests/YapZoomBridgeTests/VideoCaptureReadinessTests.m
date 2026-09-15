#import <AppKit/AppKit.h>
#import <ZoomSDK/ZoomSDK.h>
#import "YapZoomBridge.h"
#import "WHZoomRenderHost.h"
#import "WHZoomVideoDetachGrace.h"
#import <math.h>

@interface WHZoomSDKBridge (CaptureFixture)
- (void)refreshParticipants;
- (void)logVideo:(const char *)phase element:(ZoomSDKVideoElement *)element code:(NSInteger)code;
- (void)onRenderDataTypeChanged:(ZoomSDKVideoElement *)element DataType:(VideoRenderDataType)type;
- (void)onSubscribeUserFail:(ZoomSDKVideoSubscribeFailReason)error videoElement:(ZoomSDKVideoElement *)element;
- (void)suspendVideo:(NSString *)identifier element:(ZoomSDKNormalVideoElement *)element;
@end

@interface CaptureBridge : WHZoomSDKBridge
@end
@implementation CaptureBridge
- (void)refreshParticipants {}
- (void)logVideo:(const char *)phase element:(ZoomSDKVideoElement *)element code:(NSInteger)code {}
@end

@interface CaptureUser : NSObject
@property(nonatomic) BOOL cameraOn;
@end
@implementation CaptureUser
- (BOOL)isVideoOn { return self.cameraOn; }
@end

@interface CaptureHost : WHZoomRenderHost
@property(nonatomic) BOOL ready;
@end
@implementation CaptureHost
- (BOOL)isReadyForRenderer { return self.ready; }
@end

@interface CaptureElement : NSObject
@property(nonatomic) unsigned int userid;
@property(nonatomic) VideoRenderDataType dataType;
@property(nonatomic, strong) NSView *videoView;
@property(nonatomic, copy) void (^onUnsubscribe)(void);
@property(nonatomic) NSUInteger unsubscriptions;
@end
@implementation CaptureElement
- (VideoRenderDataType)getDataType { return self.dataType; }
- (ZoomSDKError)subscribeVideo:(BOOL)subscribe {
    if (!subscribe) { self.unsubscriptions++; if (self.onUnsubscribe) self.onUnsubscribe(); }
    return ZoomSDKError_Success;
}
- (ZoomSDKError)showVideo:(BOOL)show { return ZoomSDKError_Success; }
@end

@interface CaptureContainer : NSObject
@property(nonatomic) NSUInteger cleanups;
@property(nonatomic, copy) void (^onCleanup)(CaptureElement *);
@end
@implementation CaptureContainer
- (ZoomSDKError)cleanVideoElement:(CaptureElement *)element {
    self.cleanups++;
    if (self.onCleanup) self.onCleanup(element);
    return ZoomSDKError_Success;
}
@end

@interface CaptureMeeting : NSObject
@property(nonatomic, strong) CaptureUser *user;
@property(nonatomic, strong) CaptureContainer *container;
@property(nonatomic) CGSize videoSize;
@end
@implementation CaptureMeeting
- (id)getMeetingActionController { return self; }
- (id)getUserByUserID:(unsigned int)identifier { return self.user; }
- (id)getVideoContainer { return self.container; }
- (CGSize)getUserVideoSize:(unsigned int)identifier { return self.videoSize; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static CaptureElement *AttachFixture(CaptureBridge *bridge, NSString *identifier, CaptureHost *host) {
    CaptureElement *element = [CaptureElement new];
    element.userid = identifier.intValue; element.videoView = [NSView new];
    [[bridge valueForKey:@"videos"] setObject:element forKey:identifier];
    [[bridge valueForKey:@"videoHosts"] setObject:host forKey:identifier];
    [[bridge valueForKey:@"subscribedVideos"] addObject:identifier];
    return element;
}

int main(void) {
    @autoreleasepool {
        CaptureBridge *bridge = [CaptureBridge new];
        CaptureMeeting *meeting = [CaptureMeeting new];
        meeting.user = [CaptureUser new]; meeting.user.cameraOn = YES;
        meeting.container = [CaptureContainer new]; meeting.videoSize = CGSizeMake(640, 360);
        [bridge setValue:meeting forKey:@"meeting"];
        [bridge setValue:@"capture-session" forKey:@"sessionID"];
        [bridge setValue:@YES forKey:@"hasEnteredMeeting"];
        CaptureHost *host = [CaptureHost new]; host.ready = YES;
        CaptureElement *element = AttachFixture(bridge, @"7", host);
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"a mounted renderer is not evidence of video data");
        element.dataType = VideoRenderDataType_Video;
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"geometry and a getter alone cannot inherit readiness");
        [bridge onRenderDataTypeChanged:(id)element DataType:VideoRenderDataType_Video];
        Check([bridge isVideoReadyForCaptureForParticipant:@"7"], @"the current subscription reports usable live video");
        element.dataType = VideoRenderDataType_Avatar;
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"avatars are never ready for a camera capture");
        element.dataType = VideoRenderDataType_Video;
        meeting.videoSize = CGSizeZero;
        [[bridge valueForKey:@"participantVideoSizes"] setObject:[NSValue valueWithSize:CGSizeMake(640, 360)] forKey:@7];
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"cached dimensions cannot disguise an unready stream");
        meeting.videoSize = CGSizeMake(NAN, 360);
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"invalid stream geometry is rejected");
        meeting.videoSize = CGSizeMake(640, 360);
        host.ready = NO;
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"detached hosts cannot be captured");
        host.ready = YES; meeting.user.cameraOn = NO;
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"a stopped camera invalidates readiness immediately");
        meeting.user.cameraOn = YES; element.userid = 8;
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"the renderer must belong to the requested participant");
        element.userid = 7;
        [bridge onSubscribeUserFail:ZoomSDKVideoSubscribe_Fail_HasSubscribeExceededLimit videoElement:(id)element];
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"failed subscriptions cannot reuse a prior video signal");
        [bridge onRenderDataTypeChanged:(id)element DataType:VideoRenderDataType_Video];
        [bridge suspendVideo:@"7" element:(id)element];
        [[bridge valueForKey:@"subscribedVideos"] addObject:@"7"];
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"resuming requires current subscription readiness");
        [bridge onRenderDataTypeChanged:(id)element DataType:VideoRenderDataType_Video];

        // Batch switching cancels the normal container-handoff grace. Every
        // unsubscribe and cleanup must finish before the caller can attach the
        // next batch, including a late synchronous SDK callback during cleanup.
        WHZoomVideoDetachGrace *grace = [bridge valueForKey:@"videoDetachGrace"];
        __block BOOL graceRan = NO;
        [grace scheduleIdentifier:@"7" action:^{ graceRan = YES; }];
        __weak CaptureBridge *weakBridge = bridge;
        element.onUnsubscribe = ^{
            Check([[weakBridge valueForKey:@"videos"] objectForKey:@"7"] == nil, @"identity is removed before synchronous SDK callbacks");
        };
        meeting.container.onCleanup = ^(CaptureElement *oldElement) {
            [weakBridge onRenderDataTypeChanged:(id)oldElement DataType:VideoRenderDataType_Video];
            Check(![weakBridge isVideoReadyForCaptureForParticipant:@"7"], @"cleanup callbacks cannot revive the old batch");
        };
        NSUInteger previousUnsubscriptions = element.unsubscriptions;
        [bridge setVisibleParticipants:@[]];
        Check(element.unsubscriptions == previousUnsubscriptions + 1 && meeting.container.cleanups == 1,
              @"the old subscription is fully released before setVisibleParticipants returns");
        Check(![grace hasPendingIdentifier:@"7"], @"batch release cancels detach grace");
        CaptureElement *replacement = AttachFixture(bridge, @"7", host);
        replacement.dataType = VideoRenderDataType_Video;
        [bridge onRenderDataTypeChanged:(id)element DataType:VideoRenderDataType_Video];
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"an old element callback cannot mark its replacement ready");
        [bridge onRenderDataTypeChanged:(id)replacement DataType:VideoRenderDataType_Video];
        Check([bridge isVideoReadyForCaptureForParticipant:@"7"], @"the replacement becomes ready only from its own signal");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        Check(!graceRan, @"cancelled grace cannot affect a subsequent batch");
        [bridge setValue:@YES forKey:@"ending"];
        Check(![bridge isVideoReadyForCaptureForParticipant:@"7"], @"leaving invalidates readiness");
        puts("PASS: live video readiness, stale data rejection, immediate batch release, and replacement identity");
    }
    return 0;
}
