#pragma once
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ZoomSDK/ZoomSDK.h>
#import <objc/runtime.h>
#import "YapZoomBridge.h"
#import "WHZoomRenderHost.h"

// The singleton accessor is replaced before any bridge calls. These fixtures
// never initialize Zoom, authenticate over the network, or start a real camera.
@interface WHZoomSDKBridge (CameraEffectsFixture)
- (void)onZoomSDKAuthReturn:(ZoomSDKAuthError)result;
- (NSString *)cameraBackgroundKind:(ZoomSDKVirtualBGImageInfo *)item;
- (ZoomSDKVirtualBGImageInfo *)cameraBackgroundItem:(NSString *)kind path:(NSString *)path;
- (void)onRenderDataTypeChanged:(ZoomSDKVideoElement *)element DataType:(VideoRenderDataType)type;
- (void)onCameraStatusChanged:(ZoomSDKDeviceStatus)status;
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    // Include callbacks enqueued by the host's own coalesced layout update.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!drained && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    Check(drained, @"the deferred fixture callbacks complete without opening a window");
}

@interface CameraItem : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL deletable;
@property(nonatomic) BOOL video;
@property(nonatomic) BOOL selected;
@end
@implementation CameraItem
- (NSString *)getImageName { return self.name; }
- (NSString *)getImageFilePath { return self.path; }
- (BOOL)isAllowDelete { return self.deletable; }
- (BOOL)isVideo { return self.video; }
- (BOOL)isSelected { return self.selected; }
@end

@interface CameraBackground : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic, copy) NSArray<CameraItem *> *items;
@property(nonatomic) BOOL supported;
@property(nonatomic) BOOL ignoreSelection;
@property(nonatomic) NSUInteger uses;
@end
@implementation CameraBackground
- (NSArray *)getBGItemList { return self.items; }
- (BOOL)isSupportVirtualBG { return self.supported; }
- (BOOL)isDeviceSupportSmartVirtualBG { return YES; }
- (BOOL)isAllowAddNewVBItem { return YES; }
- (BOOL)isUsingGreenScreenOn { return NO; }
- (ZoomSDKError)useBGItem:(CameraItem *)item {
    self.uses++;
    if (!self.ignoreSelection) for (CameraItem *candidate in self.items) candidate.selected = candidate == item;
    return ZoomSDKError_Success;
}
@end

@interface CameraTestHelper : NSObject
@property(nonatomic, weak) NSView *parent;
@property(nonatomic) NSRect rect;
@property(nonatomic) NSUInteger bindings;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger stops;
@property(nonatomic) ZoomSDKError bindingResult;
@property(nonatomic) ZoomSDKError startResult;
@property(nonatomic) ZoomSDKError stopResult;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *startResults;
@property(nonatomic, copy) void (^onStop)(void);
@end
@implementation CameraTestHelper
- (ZoomSDKError)SetVideoParentView:(NSView *)parent VideoContainerRect:(NSRect)rect {
    self.parent = parent; self.rect = rect; self.bindings++; return self.bindingResult;
}
- (ZoomSDKError)StartPreview {
    self.starts++;
    if (!self.startResults.count) return self.startResult;
    ZoomSDKError result = self.startResults.firstObject.unsignedIntegerValue;
    [self.startResults removeObjectAtIndex:0]; return result;
}
- (ZoomSDKError)StopPreview { self.stops++; if (self.onStop) self.onStop(); return self.stopResult; }
@end

@interface CameraDevice : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) BOOL selected;
@end
@implementation CameraDevice
- (NSString *)getDeviceID { return self.identifier; }
- (NSString *)getDeviceName { return @"Inert fixture camera"; }
- (BOOL)isSelectedDevice { return self.selected; }
@end

@interface CameraVideoSetting : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) BOOL hd;
@property(nonatomic) BOOL autoFraming;
@property(nonatomic) BOOL ignoreFraming;
@property(nonatomic, copy) NSArray<CameraDevice *> *cameras;
@property(nonatomic) NSUInteger selections;
@property(nonatomic) ZoomSDKError selectionResult;
@property(nonatomic, strong) CameraTestHelper *helper;
@property(nonatomic) NSUInteger framingSets;
@end
@implementation CameraVideoSetting
- (ZoomSDKError)enableCatchHDVideo:(BOOL)enabled { self.hd = enabled; return ZoomSDKError_Success; }
- (BOOL)isCatchHDVideoOn { return self.hd; }
- (BOOL)isVideoAutoFramingEnabled { return self.autoFraming; }
- (ZoomSDKAutoFramingMode)getVideoAutoFramingMode { return ZoomSDKAutoFramingMode_Face_Recognition; }
- (ZoomSDKError)enableVideoAutoFraming:(ZoomSDKAutoFramingMode)mode setting:(ZoomSDKAutoFramingParameter *)parameters {
    self.framingSets++;
    if (!self.ignoreFraming) self.autoFraming = YES;
    return ZoomSDKError_Success;
}
- (ZoomSDKError)disableVideoAutoFraming {
    self.framingSets++;
    if (!self.ignoreFraming) self.autoFraming = NO;
    return ZoomSDKError_Success;
}
- (NSArray *)getCameraList { return self.cameras; }
- (id)getSettingVideoTestHelper { return self.helper; }
- (ZoomSDKError)selectCamera:(NSString *)identifier {
    self.selections++;
    if (self.selectionResult == ZoomSDKError_Success) for (CameraDevice *camera in self.cameras) camera.selected = [camera.identifier isEqualToString:identifier];
    return self.selectionResult;
}
@end

@interface CameraSettings : NSObject
@property(nonatomic, strong) CameraBackground *background;
@property(nonatomic, strong) CameraVideoSetting *video;
@end
@implementation CameraSettings
- (id)getVirtualBGSetting { return self.background; }
- (id)getVideoSetting { return self.video; }
- (id)getAudioSetting { return nil; }
@end

@interface CameraAuth : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) NSUInteger requests;
@end
@implementation CameraAuth
- (ZoomSDKError)sdkAuth:(ZoomSDKAuthContext *)context { self.requests++; return ZoomSDKError_Success; }
- (BOOL)isAuthorized { return YES; }
@end

@interface CameraAction : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) NSUInteger unmutes;
@property(nonatomic) NSUInteger mutes;
@property(nonatomic, strong) NSMutableArray<NSString *> *operations;
@end
@implementation CameraAction
- (ZoomSDKError)actionMeetingWithCmd:(ActionMeetingCmd)command userID:(unsigned int)userID onScreen:(ScreenType)screen {
    if (command == ActionMeetingCmd_UnMuteVideo) { self.unmutes++; [self.operations addObject:@"unmute"]; }
    if (command == ActionMeetingCmd_MuteVideo) { self.mutes++; [self.operations addObject:@"mute"]; }
    return ZoomSDKError_Success;
}
- (id)getMyself { return self; }
- (BOOL)isVideoOn { return NO; }
@end

@interface CameraContainer : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) NSUInteger cleanups;
@property(nonatomic, copy) void (^onCleanup)(void);
@property(nonatomic, strong) id lastPreview;
@property(nonatomic) NSUInteger creations;
@end
@implementation CameraContainer
- (ZoomSDKError)createPreViewVideoElement:(id __autoreleasing *)element {
    self.creations++; self.lastPreview = *element; return ZoomSDKError_Success;
}
- (ZoomSDKError)cleanVideoElement:(id)element {
    self.cleanups++;
    if (self.onCleanup) self.onCleanup();
    return ZoomSDKError_Success;
}
@end

@interface CameraMeeting : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) CameraAction *action;
@property(nonatomic, strong) CameraContainer *container;
@property(nonatomic) NSUInteger leaves;
@property(nonatomic) NSUInteger joins;
@property(nonatomic) ZoomSDKMeetingStatus status;
@end
@implementation CameraMeeting
- (instancetype)init { if ((self = [super init])) self.status = ZoomSDKMeetingStatus_InMeeting; return self; }
- (id)getMeetingActionController { return self.action; }
- (id)getVideoContainer { return self.container; }
- (id)getMeetingChatController { return nil; }
- (id)getASController { return nil; }
- (id)getWaitingRoomController { return nil; }
- (id)getMeetingIndicatorController { return nil; }
- (id)getRecordController { return nil; }
- (ZoomSDKMeetingStatus)getMeetingStatus { return self.status; }
- (ZoomSDKError)leaveMeetingWithCmd:(LeaveMeetingCmd)command { self.leaves++; return ZoomSDKError_Success; }
- (ZoomSDKError)joinMeeting:(id)parameters { self.joins++; return ZoomSDKError_Success; }
- (ZoomSDKError)startMeetingWithZAK:(id)parameters { self.joins++; return ZoomSDKError_Success; }
@end

@interface CameraSDK : NSObject
@property(nonatomic, strong) CameraSettings *settings;
@property(nonatomic, strong) CameraAuth *auth;
@property(nonatomic, strong) CameraMeeting *meeting;
@property(nonatomic) NSUInteger initializations;
@property(nonatomic) NSUInteger uninitializations;
@end
@implementation CameraSDK
- (ZoomSDKError)initSDKWithParams:(id)parameters { self.initializations++; return ZoomSDKError_Success; }
- (void)unInitSDK { self.uninitializations++; }
- (id)getAuthService { return self.auth; }
- (id)getSettingService { return self.settings; }
- (id)getMeetingService { return self.meeting; }
- (id)getReminderHelper { return nil; }
@end

@interface CameraPreview : NSObject
@property(nonatomic, strong) NSView *view;
@property(nonatomic) NSUInteger stops;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger showRequests;
@property(nonatomic) VideoRenderDataType dataType;
@end
@implementation CameraPreview
- (instancetype)initWithFrame:(NSRect)rect { if ((self = [super init])) self.view = [[NSView alloc] initWithFrame:rect]; return self; }
- (ZoomSDKError)startPreview:(BOOL)start { if (start) self.starts++; else self.stops++; return ZoomSDKError_Success; }
- (ZoomSDKError)showVideo:(BOOL)show { if (show) self.showRequests++; return ZoomSDKError_Success; }
- (NSView *)getVideoView { return self.view; }
- (ZoomSDKError)resize:(NSRect)rect { self.view.frame = rect; return ZoomSDKError_Success; }
- (VideoRenderDataType)getDataType { return self.dataType; }
@end

@interface CameraGateBridge : WHZoomSDKBridge
@property(nonatomic) NSInteger applyResult;
@property(nonatomic, strong) NSMutableArray<NSString *> *operations;
@property(nonatomic, copy) NSString *appliedBackground;
@property(nonatomic) BOOL appliedFraming;
@end
@implementation CameraGateBridge
- (NSInteger)applyCameraBackground:(NSString *)background imagePath:(NSString *)path autoFraming:(BOOL)framing {
    [self.operations addObject:@"apply"];
    self.appliedBackground = background; self.appliedFraming = framing;
    return self.applyResult;
}
- (void)refreshVideoStatistics {}
@end

@interface CameraStateBridge : WHZoomSDKBridge
@end
@implementation CameraStateBridge
- (void)refreshVideoStatistics {}
@end

static CameraItem *Item(NSString *name, NSString *path, BOOL deletable) {
    CameraItem *item = [CameraItem new]; item.name = name; item.path = path; item.deletable = deletable;
    return item;
}

static CameraSDK *fixtureSDK;
static id FixtureSharedSDK(id receiver, SEL selector) { return fixtureSDK; }
static id __attribute__((ns_returns_retained)) FixturePreviewAlloc(id receiver, SEL selector) { return [CameraPreview new]; }
static AVAuthorizationStatus fixtureCameraAuthorization = AVAuthorizationStatusAuthorized;
static AVAuthorizationStatus FixtureCameraAuthorization(id receiver, SEL selector, AVMediaType mediaType) { return fixtureCameraAuthorization; }
static BOOL fixtureRendererReady;
static BOOL FixtureRendererReady(id receiver, SEL selector) { return fixtureRendererReady; }
