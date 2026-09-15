#import "CameraEffectsFixture.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fixtureSDK = [CameraSDK new];
        fixtureSDK.settings = [CameraSettings new];
        fixtureSDK.settings.background = [CameraBackground new]; fixtureSDK.settings.video = [CameraVideoSetting new];
        fixtureSDK.settings.video.helper = [CameraTestHelper new];
        fixtureSDK.settings.background.supported = YES;
        fixtureSDK.auth = [CameraAuth new]; fixtureSDK.meeting = [CameraMeeting new];
        fixtureSDK.meeting.action = [CameraAction new]; fixtureSDK.meeting.container = [CameraContainer new];
        Method shared = class_getClassMethod(ZoomSDK.class, @selector(sharedSDK));
        Check(shared != NULL, @"the SDK accessor is available for the inert fixture");
        IMP original = method_setImplementation(shared, (IMP)FixtureSharedSDK);

        CameraGateBridge *bridge = [CameraGateBridge new];
        bridge.operations = [NSMutableArray array]; fixtureSDK.meeting.action.operations = bridge.operations;
        __block NSUInteger completions = 0;
        Check([bridge prepareCameraEffectsWithJWT:@"inert-fixture" completion:^(NSInteger code, NSString *message) {
            completions++; Check(code == 0, @"settings authorization completes successfully");
        }] == 0, @"settings preparation requests fixture authentication");
        Check(completions == 0 && fixtureSDK.auth.requests == 1, @"preparation waits for authentication");
        [bridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        Check(completions == 1 && bridge.cameraEffectsReady, @"auth success prepares settings exactly once");
        Check(fixtureSDK.meeting.joins == 0 && fixtureSDK.meeting.action.unmutes == 0,
              @"settings authentication never joins a meeting or starts sending video");

        CameraItem *none = Item(@"NewUI_Settings_None", nil, NO);
        CameraItem *blur = Item(@"Blur", nil, NO);
        CameraItem *importedBlur = Item(@"Blur", @"/fixtures/Blur.jpg", YES);
        CameraItem *importedNone = Item(@"NewUI_Settings_None", @"/fixtures/None.png", YES);
        fixtureSDK.settings.background.items = @[importedBlur, blur, importedNone, none];
        Check([bridge cameraBackgroundItem:@"none" path:nil] == (id)none, @"None is found by its built-in identity after reordering");
        Check([bridge cameraBackgroundItem:@"blur" path:nil] == (id)blur, @"Blur is found without trusting list position or imported names");
        Check([bridge cameraBackgroundKind:(id)importedBlur] == nil && [bridge cameraBackgroundKind:(id)importedNone] == nil,
              @"deletable user photos cannot impersonate built-in effects");
        Check([bridge cameraBackgroundItem:@"image" path:@"/fixtures/../fixtures/Blur.jpg"] == (id)importedBlur,
              @"an imported photo remains selectable by its normalized path");
        fixtureSDK.settings.background.items = @[importedBlur, importedNone];
        Check([bridge cameraBackgroundItem:@"blur" path:nil] == nil && [bridge cameraBackgroundItem:@"none" path:nil] == nil,
              @"missing built-ins do not fall back to arbitrary list items");
        blur.video = YES;
        Check([bridge cameraBackgroundKind:(id)blur] == nil, @"a video cannot impersonate built-in Blur");
        blur.video = NO;
        fixtureSDK.settings.background.items = @[none, blur]; none.selected = YES;

        // Give the already authorized bridge a synthetic active meeting. Closing
        // the settings panel must preserve that meeting and its delegates.
        [bridge setValue:@NO forKey:@"cameraSettingsOnly"];
        [bridge setValue:@"camera-fixture-session" forKey:@"sessionID"];
        [bridge setValue:@YES forKey:@"hasEnteredMeeting"];
        fixtureSDK.meeting.delegate = bridge; fixtureSDK.meeting.action.delegate = bridge;
        fixtureSDK.meeting.container.delegate = bridge;
        [bridge setPreferredCameraBackground:@"blur" imagePath:nil autoFraming:YES];
        bridge.applyResult = ZoomSDKError_NoPermission;
        Check([bridge setCameraEnabled:YES] != 0, @"a denied effect fails the camera-start request");
        Check(fixtureSDK.meeting.action.unmutes == 0 && [bridge.operations isEqualToArray:@[@"apply"]],
              @"effect failure prevents every outgoing camera-start command");
        Check([bridge setCameraEnabled:NO] == 0 && fixtureSDK.meeting.action.mutes == 1,
              @"turning off the camera still works when effects fail");
        Check([bridge.operations isEqualToArray:@[@"apply", @"mute"]], @"camera-off never depends on applying effects");
        [bridge.operations removeAllObjects]; bridge.applyResult = 0;
        Check([bridge setCameraEnabled:YES] == 0 && fixtureSDK.meeting.action.unmutes == 1,
              @"camera starts after the effect succeeds");
        Check([bridge.operations isEqualToArray:@[@"apply", @"unmute"]] && [bridge.appliedBackground isEqualToString:@"blur"] && bridge.appliedFraming,
              @"the current preferred effects are applied before the first outgoing frame");

        NSUInteger uninitializations = fixtureSDK.uninitializations;
        NSUInteger cameraCommands = fixtureSDK.meeting.action.unmutes + fixtureSDK.meeting.action.mutes;
        [bridge closeCameraEffects];
        Check(fixtureSDK.meeting.leaves == 0 && fixtureSDK.uninitializations == uninitializations &&
              fixtureSDK.meeting.action.unmutes + fixtureSDK.meeting.action.mutes == cameraCommands,
              @"closing settings never leaves, uninitializes, or toggles the meeting camera");
        Check(fixtureSDK.meeting.delegate == bridge && fixtureSDK.meeting.action.delegate == bridge && fixtureSDK.meeting.container.delegate == bridge,
              @"closing settings preserves every active meeting delegate");
        [bridge closeCameraEffects];
        Check(fixtureSDK.uninitializations == uninitializations && fixtureSDK.meeting.leaves == 0,
              @"repeated settings closure keeps the active meeting intact");

        // Release the synthetic session before exercising cancellation of a
        // distinct authentication attempt; no actual meeting exists here.
        [bridge setValue:nil forKey:@"sessionID"]; [bridge setValue:@YES forKey:@"cameraSettingsOnly"];
        [bridge closeCameraEffects];
        WHZoomSDKBridge *cancelled = [WHZoomSDKBridge new];
        __block NSUInteger cancellations = 0;
        Check([cancelled prepareCameraEffectsWithJWT:@"cancelled-fixture" completion:^(NSInteger code, NSString *message) {
            cancellations++; Check(code != 0, @"closed authentication is reported as cancellation/failure");
        }] == 0, @"a subsequent settings session can acquire the released SDK");
        [cancelled closeCameraEffects];
        NSUInteger joins = fixtureSDK.meeting.joins;
        [cancelled onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        Check(cancellations == 1 && !cancelled.cameraEffectsReady && fixtureSDK.meeting.joins == joins,
              @"late authentication cannot revive closed settings or complete twice");

        // Exercise the real apply implementation with SDK setters that report
        // success while their readback deliberately remains unchanged.
        CameraStateBridge *stateBridge = [CameraStateBridge new];
        Check([stateBridge prepareCameraEffectsWithJWT:@"readback-fixture" completion:^(NSInteger code, NSString *message) {
            Check(code == 0, @"the readback fixture authorizes settings");
        }] == 0, @"readback fixture acquires the SDK");
        [stateBridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        [stateBridge setValue:@NO forKey:@"cameraSettingsOnly"];
        [stateBridge setValue:@"readback-fixture-session" forKey:@"sessionID"];
        [stateBridge setValue:@YES forKey:@"hasEnteredMeeting"];
        fixtureSDK.settings.background.items = @[none, blur]; none.selected = YES; blur.selected = NO;
        fixtureSDK.settings.background.ignoreSelection = YES;
        [stateBridge setPreferredCameraBackground:@"blur" imagePath:nil autoFraming:NO];
        NSUInteger unmutes = fixtureSDK.meeting.action.unmutes;
        Check([stateBridge setCameraEnabled:YES] != 0 && fixtureSDK.meeting.action.unmutes == unmutes,
              @"a successful setter with unchanged background readback cannot start sending");
        Check(stateBridge.cameraEffectsAwaitingConfirmation, @"successful background submission waits for asynchronous SDK readback");
        NSUInteger backgroundUses = fixtureSDK.settings.background.uses;
        NSUInteger framingSets = fixtureSDK.settings.video.framingSets;
        Check([stateBridge confirmCameraBackground:@"blur" imagePath:nil autoFraming:NO] != 0 && stateBridge.cameraEffectsAwaitingConfirmation,
              @"unconfirmed readback remains pending without claiming applied effects");
        none.selected = NO; blur.selected = YES;
        Check([stateBridge confirmCameraBackground:@"blur" imagePath:nil autoFraming:NO] == 0 && !stateBridge.cameraEffectsAwaitingConfirmation,
              @"later background readback confirms the original request");
        Check(fixtureSDK.settings.background.uses == backgroundUses && fixtureSDK.settings.video.framingSets == framingSets &&
              fixtureSDK.meeting.action.unmutes == unmutes,
              @"confirmation polls are pure readback and cannot resubmit settings or start the outgoing camera");
        fixtureSDK.settings.background.ignoreSelection = NO;
        fixtureSDK.settings.video.ignoreFraming = YES;
        [stateBridge setPreferredCameraBackground:@"none" imagePath:nil autoFraming:YES];
        Check([stateBridge setCameraEnabled:YES] != 0 && fixtureSDK.meeting.action.unmutes == unmutes,
              @"a successful setter with unchanged framing readback cannot start sending");
        Check(stateBridge.cameraEffectsAwaitingConfirmation, @"successful framing submission also waits for SDK readback");
        backgroundUses = fixtureSDK.settings.background.uses; framingSets = fixtureSDK.settings.video.framingSets;
        fixtureSDK.settings.video.autoFraming = YES;
        Check([stateBridge confirmCameraBackground:@"none" imagePath:nil autoFraming:YES] == 0 && !stateBridge.cameraEffectsAwaitingConfirmation,
              @"later framing readback completes confirmation");
        Check(fixtureSDK.settings.background.uses == backgroundUses && fixtureSDK.settings.video.framingSets == framingSets,
              @"framing confirmation does not repeat native setters");
        fixtureSDK.settings.video.ignoreFraming = NO;
        fixtureSDK.settings.background.items = @[];
        [stateBridge setPreferredCameraBackground:@"none" imagePath:nil autoFraming:NO];
        Check([stateBridge setCameraEnabled:YES] != 0 && fixtureSDK.meeting.action.unmutes == unmutes,
              @"a supported but empty background list cannot confirm None before sending");
        fixtureSDK.settings.background.items = @[none, blur];
        [stateBridge setPreferredCameraBackground:@"blur" imagePath:nil autoFraming:YES];
        Check([stateBridge setCameraEnabled:YES] == 0 && fixtureSDK.meeting.action.unmutes == unmutes + 1,
              @"confirmed real background and framing setters allow sending");
        NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[stateBridge cameraEffectsSnapshot] options:0 error:nil];
        Check([state[@"applied"][@"background"] isEqualToString:@"blur"] && [state[@"applied"][@"autoFraming"] boolValue],
              @"the snapshot reports confirmed SDK readback");

        NSString *temporaryRoot = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
        NSURL *photoDirectory = [NSURL fileURLWithPath:[temporaryRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                          isDirectory:YES];
        Check([[NSFileManager defaultManager] createDirectoryAtURL:photoDirectory withIntermediateDirectories:YES attributes:nil error:nil],
              @"copied-image fixtures have a temporary directory");
        NSURL *firstPhoto = [photoDirectory URLByAppendingPathComponent:@"first-import.png"];
        NSURL *secondPhoto = [photoDirectory URLByAppendingPathComponent:@"second-import.png"];
        NSURL *sdkPhoto = [photoDirectory URLByAppendingPathComponent:@"zoom-copy.png"];
        NSData *photoBytes = [@"identical inert photo bytes" dataUsingEncoding:NSUTF8StringEncoding];
        for (NSURL *url in @[firstPhoto, secondPhoto, sdkPhoto]) Check([photoBytes writeToURL:url atomically:YES], @"photo byte fixtures are writable");
        CameraItem *copiedPhoto = Item(@"zoom-copy.png", sdkPhoto.path, YES);
        fixtureSDK.settings.background.items = @[none, blur, copiedPhoto];
        Check([stateBridge applyCameraBackground:@"image" imagePath:firstPhoto.path autoFraming:YES] == 0,
              @"a copied SDK photo can be recovered by byte identity");
        state = [NSJSONSerialization JSONObjectWithData:[stateBridge cameraEffectsSnapshot] options:0 error:nil];
        Check([state[@"applied"][@"imagePath"] isEqualToString:firstPhoto.path], @"photo readback preserves the requested original path");
        Check([stateBridge applyCameraBackground:@"image" imagePath:secondPhoto.path autoFraming:YES] == 0,
              @"reimporting identical bytes can select the same SDK photo");
        state = [NSJSONSerialization JSONObjectWithData:[stateBridge cameraEffectsSnapshot] options:0 error:nil];
        Check([state[@"applied"][@"imagePath"] isEqualToString:secondPhoto.path],
              @"identical photo aliases report the current requested path rather than an arbitrary older import");
        Check([[NSFileManager defaultManager] removeItemAtURL:photoDirectory error:nil], @"temporary photo byte fixtures are removed");
        fixtureSDK.settings.background.ignoreSelection = YES;
        Check([stateBridge applyCameraBackground:@"none" imagePath:nil autoFraming:YES] != 0 && stateBridge.cameraEffectsAwaitingConfirmation,
              @"the closing fixture has an outstanding background confirmation");
        backgroundUses = fixtureSDK.settings.background.uses; framingSets = fixtureSDK.settings.video.framingSets;
        [stateBridge setValue:nil forKey:@"sessionID"]; [stateBridge setValue:@YES forKey:@"cameraSettingsOnly"];
        [stateBridge closeCameraEffects];
        Check(!stateBridge.cameraEffectsAwaitingConfirmation, @"teardown immediately clears an outstanding effects confirmation");
        Check([stateBridge confirmCameraBackground:@"none" imagePath:nil autoFraming:YES] != 0 &&
              !stateBridge.cameraEffectsAwaitingConfirmation,
              @"closed settings reject late confirmation and cannot remain pending");
        Check(fixtureSDK.settings.background.uses == backgroundUses && fixtureSDK.settings.video.framingSets == framingSets,
              @"cancellation cannot resubmit pending effects");
        fixtureSDK.settings.background.ignoreSelection = NO;

        // No native preview is even allocated: substitute its allocator and
        // permission getter, then drive the render host's readiness callback.
        Class previewMetaClass = object_getClass(ZoomSDKPreViewVideoElement.class);
        Method previewAllocator = class_getClassMethod(ZoomSDKPreViewVideoElement.class, @selector(alloc));
        IMP originalPreviewAllocator = method_getImplementation(previewAllocator);
        const char *allocatorTypes = method_getTypeEncoding(previewAllocator);
        class_replaceMethod(previewMetaClass, @selector(alloc), (IMP)FixturePreviewAlloc, allocatorTypes);
        Method authorization = class_getClassMethod(AVCaptureDevice.class, @selector(authorizationStatusForMediaType:));
        IMP originalAuthorization = method_setImplementation(authorization, (IMP)FixtureCameraAuthorization);
        Method readiness = class_getInstanceMethod(WHZoomRenderHost.class, @selector(isReadyForRenderer));
        IMP originalReadiness = method_setImplementation(readiness, (IMP)FixtureRendererReady);
        fixtureRendererReady = NO;
        CameraGateBridge *previewBridge = [CameraGateBridge new]; previewBridge.operations = [NSMutableArray array];
        Check([previewBridge prepareCameraEffectsWithJWT:@"mounted-preview-fixture" completion:^(NSInteger code, NSString *message) {
            Check(code == 0, @"the inert preview fixture authorizes settings");
        }] == 0, @"the deferred preview fixture acquires the SDK");
        [previewBridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        CameraTestHelper *helper = fixtureSDK.settings.video.helper;
        __weak CameraGateBridge *weakPreviewBridge = previewBridge;
        helper.onStop = ^{
            Check([weakPreviewBridge valueForKey:@"cameraPreviewHelper"] == nil && [weakPreviewBridge valueForKey:@"cameraPreviewHost"] == nil,
                  @"preview identity is removed before synchronous helper stop callbacks");
        };
        fixtureSDK.settings.background.items = @[none, blur]; none.selected = YES; blur.selected = NO;
        fixtureSDK.meeting.container.onCleanup = nil;
        fixtureSDK.settings.video.cameras = @[];
        NSUInteger creations = fixtureSDK.meeting.container.creations;
        Check([previewBridge startCameraEffectsPreview] == nil && fixtureSDK.meeting.container.creations == creations && helper.starts == 0,
              @"missing cameras fail before allocating a preview");
        CameraDevice *invalidCamera = [CameraDevice new]; invalidCamera.identifier = @""; invalidCamera.selected = YES;
        fixtureSDK.settings.video.cameras = @[invalidCamera];
        Check([previewBridge startCameraEffectsPreview] == nil && fixtureSDK.meeting.container.creations == creations && helper.starts == 0,
              @"an invalid selected camera identifier is not treated as available");

        CameraDevice *firstCamera = [CameraDevice new]; firstCamera.identifier = @"first-fixture-camera";
        CameraDevice *selectedCamera = [CameraDevice new]; selectedCamera.identifier = @"selected-fixture-camera"; selectedCamera.selected = YES;
        fixtureSDK.settings.video.cameras = @[firstCamera, selectedCamera];
        WHZoomRenderHost *unmountedHost = (id)[previewBridge startCameraEffectsPreview];
        Check(unmountedHost != nil && helper.starts == 0 && fixtureSDK.settings.video.selections == 0 && fixtureSDK.meeting.container.creations == creations,
              @"an existing camera selection is preserved and preview capture waits for mounting");
        Check(unmountedHost.reconcileRenderer != nil, @"the preview host has a deferred start callback");
        void (^staleMount)(BOOL) = [unmountedHost.reconcileRenderer copy];
        unmountedHost.reconcileRenderer(NO);
        Check(helper.starts == 0, @"an unready host cannot start capture");
        [previewBridge stopCameraEffectsPreview];
        fixtureRendererReady = YES; staleMount(YES);
        DrainMainQueue();
        Check(helper.starts == 0 && helper.stops == 0,
              @"cancelling before mount neither starts capture later nor stops a camera it never opened");

        WHZoomRenderHost *cancelledHost = (id)[previewBridge startCameraEffectsPreview];
        Check(cancelledHost != nil, @"a cancellation fixture can create a new preview host");
        cancelledHost.resizeRenderer(cancelledHost.bounds);
        cancelledHost.reconcileRenderer(YES);
        Check(helper.starts == 0, @"mounting binds the helper without starting capture in the same turn");
        [previewBridge stopCameraEffectsPreview];
        DrainMainQueue();
        Check(helper.starts == 0 && helper.stops == 1,
              @"stopping after binding cancels the queued start and stops capture that SDK appearance may have opened");

        WHZoomRenderHost *closedHost = (id)[previewBridge startCameraEffectsPreview];
        Check(closedHost != nil, @"a close fixture can create a new preview host");
        closedHost.resizeRenderer(closedHost.bounds);
        closedHost.reconcileRenderer(YES);
        [previewBridge closeCameraEffects];
        DrainMainQueue();
        Check(helper.starts == 0 && helper.stops == 2,
              @"closing settings stops the bound helper and cancels a queued start before relinquishing SDK ownership");
        Check([previewBridge prepareCameraEffectsWithJWT:@"remounted-preview-fixture" completion:^(NSInteger code, NSString *message) {
            Check(code == 0, @"settings can authorize again after cancelling a queued preview");
        }] == 0, @"the preview fixture reacquires the SDK after closing");
        [previewBridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];

        WHZoomRenderHost *deniedBindingHost = (id)[previewBridge startCameraEffectsPreview];
        Check(deniedBindingHost != nil, @"a pre-binding permission fixture creates a preview host");
        NSUInteger bindingsBeforePermissionLoss = helper.bindings;
        fixtureCameraAuthorization = AVAuthorizationStatusDenied;
        deniedBindingHost.resizeRenderer(deniedBindingHost.bounds);
        DrainMainQueue();
        NSDictionary *deniedBindingState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(helper.bindings == bindingsBeforePermissionLoss && helper.starts == 0 && helper.stops == 2 &&
              [previewBridge valueForKey:@"cameraPreviewHost"] == nil && [deniedBindingState[@"previewError"] length] > 0,
              @"permission revoked before mounting blocks parent binding and its implicit native appearance capture");
        fixtureCameraAuthorization = AVAuthorizationStatusAuthorized;

        helper.bindingResult = ZoomSDKError_InvalidParameter;
        WHZoomRenderHost *bindingFailureHost = (id)[previewBridge startCameraEffectsPreview];
        Check(bindingFailureHost != nil, @"a binding failure fixture creates a preview host");
        void (^staleFailedBinding)(BOOL) = [bindingFailureHost.reconcileRenderer copy];
        bindingFailureHost.resizeRenderer(NSZeroRect);
        staleFailedBinding(YES);
        DrainMainQueue();
        NSDictionary *bindingFailureState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(helper.starts == 0 && helper.stops == 3 && [previewBridge valueForKey:@"cameraPreviewHost"] == nil &&
              [bindingFailureState[@"previewError"] length] > 0,
              @"a rejected binding with malformed geometry stops partial SDK setup and rejects late mount callbacks");
        helper.bindingResult = ZoomSDKError_Success;

        WHZoomRenderHost *hiddenHost = (id)[previewBridge startCameraEffectsPreview];
        Check(hiddenHost != nil, @"a readiness fixture can create a preview host");
        hiddenHost.resizeRenderer(hiddenHost.bounds);
        hiddenHost.reconcileRenderer(YES);
        fixtureRendererReady = NO;
        DrainMainQueue();
        Check(helper.starts == 0 && ![[previewBridge valueForKey:@"cameraPreviewStartScheduled"] boolValue],
              @"a host hidden before the deferred callback cannot start capture and can later retry");
        [previewBridge stopCameraEffectsPreview];
        Check(helper.stops == 4, @"stopping a hidden bound host closes any SDK-managed appearance capture");

        fixtureRendererReady = YES;
        WHZoomRenderHost *permissionHost = (id)[previewBridge startCameraEffectsPreview];
        Check(permissionHost != nil, @"a permission fixture can create a preview host");
        permissionHost.resizeRenderer(permissionHost.bounds);
        permissionHost.reconcileRenderer(YES);
        fixtureCameraAuthorization = AVAuthorizationStatusDenied;
        DrainMainQueue();
        NSDictionary *deniedState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(helper.starts == 0 && helper.stops == 5 && [previewBridge valueForKey:@"cameraPreviewHost"] == nil &&
              [deniedState[@"previewError"] length] > 0,
              @"permission loss before the deferred callback stops the bound helper without an explicit start");
        fixtureCameraAuthorization = AVAuthorizationStatusAuthorized;

        fixtureRendererReady = NO; selectedCamera.selected = NO;
        fixtureSDK.settings.video.selectionResult = ZoomSDKError_NoPermission;
        creations = fixtureSDK.meeting.container.creations;
        Check([previewBridge startCameraEffectsPreview] == nil && fixtureSDK.meeting.container.creations == creations,
              @"camera selection failure leaves capture unopened");
        fixtureSDK.settings.video.selectionResult = ZoomSDKError_Success;
        NSUInteger selections = fixtureSDK.settings.video.selections;
        WHZoomRenderHost *mountedHost = (id)[previewBridge startCameraEffectsPreview];
        Check(mountedHost != nil && firstCamera.selected && fixtureSDK.settings.video.selections == selections + 1 && helper.starts == 0,
              @"a first camera is selected only when the SDK has no selected usable camera");
        staleMount(YES);
        Check(helper.starts == 0, @"old readiness callbacks cannot activate a replacement preview");
        fixtureRendererReady = YES;
        if (mountedHost.resizeRenderer) mountedHost.resizeRenderer(mountedHost.bounds);
        mountedHost.reconcileRenderer(YES); mountedHost.reconcileRenderer(YES);
        Check(helper.starts == 0, @"repeated mount callbacks coalesce capture until the next main-queue turn");
        DrainMainQueue();
        Check(helper.starts == 1 && helper.parent == mountedHost && NSEqualRects(helper.rect, mountedHost.bounds) && fixtureSDK.meeting.container.creations == creations,
              @"standalone settings binds the ready host and starts the video-test helper exactly once");
        void (^staleHelperMount)(BOOL) = [mountedHost.reconcileRenderer copy];
        [previewBridge onCameraStatusChanged:No_Device];
        NSDictionary *previewState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(![previewState[@"isPreviewing"] boolValue] && [previewState[@"previewError"] length] > 0 && helper.stops == 6,
              @"camera loss stops the preview and reports an actionable asynchronous error");
        [previewBridge stopCameraEffectsPreview];
        Check(helper.stops == 6, @"repeated helper cleanup never stops the camera twice");

        fixtureRendererReady = NO; helper.startResult = ZoomSDKError_NoPermission;
        WHZoomRenderHost *failedHost = (id)[previewBridge startCameraEffectsPreview];
        Check(failedHost != nil && helper.starts == 1, @"a helper start failure remains deferred until mounting");
        fixtureRendererReady = YES; failedHost.reconcileRenderer(YES);
        DrainMainQueue();
        previewState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(![previewState[@"isPreviewing"] boolValue] && [previewState[@"previewError"] length] > 0 && helper.starts == 2,
              @"a failed helper start releases the preview and reports an asynchronous error");
        helper.startResult = ZoomSDKError_Success;

        // Native appearance can already mark the preview as running. A public
        // stop/start normalization must obtain an actual successful start.
        void (^cleanupStopAssertion)(void) = [helper.onStop copy];
        helper.onStop = nil;
        NSUInteger startsBeforeNormalization = helper.starts;
        NSUInteger stopsBeforeNormalization = helper.stops;
        helper.startResults = [@[@(ZoomSDKError_WrongUsage), @(ZoomSDKError_Success)] mutableCopy];
        WHZoomRenderHost *normalizedHost = (id)[previewBridge startCameraEffectsPreview];
        Check(normalizedHost != nil, @"a normalization fixture creates a preview host");
        normalizedHost.resizeRenderer(normalizedHost.bounds); normalizedHost.reconcileRenderer(YES);
        DrainMainQueue();
        Check(helper.starts == startsBeforeNormalization + 2 && helper.stops == stopsBeforeNormalization + 1 &&
              [previewBridge valueForKey:@"cameraPreviewHost"] == normalizedHost,
              @"an already-running preview is stopped once and succeeds only after a successful second start");
        helper.onStop = cleanupStopAssertion;
        [previewBridge stopCameraEffectsPreview];
        Check(helper.stops == stopsBeforeNormalization + 2,
              @"closing a normalized preview adds exactly one final cleanup stop");

        helper.onStop = nil;
        startsBeforeNormalization = helper.starts; stopsBeforeNormalization = helper.stops;
        helper.stopResult = ZoomSDKError_ServiceFailed;
        helper.startResults = [@[@(ZoomSDKError_WrongUsage), @(ZoomSDKError_Success)] mutableCopy];
        WHZoomRenderHost *stopFailureHost = (id)[previewBridge startCameraEffectsPreview];
        Check(stopFailureHost != nil, @"a normalization stop-failure fixture creates a preview host");
        stopFailureHost.resizeRenderer(stopFailureHost.bounds); stopFailureHost.reconcileRenderer(YES);
        DrainMainQueue();
        previewState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(helper.starts == startsBeforeNormalization + 1 && helper.stops == stopsBeforeNormalization + 2 &&
              [previewBridge valueForKey:@"cameraPreviewHost"] == nil && [previewState[@"previewError"] length] > 0,
              @"a failed normalization stop cannot retry capture and still attempts final cleanup");
        helper.stopResult = ZoomSDKError_Success;

        startsBeforeNormalization = helper.starts; stopsBeforeNormalization = helper.stops;
        helper.startResults = [@[@(ZoomSDKError_WrongUsage), @(ZoomSDKError_WrongUsage)] mutableCopy];
        WHZoomRenderHost *retryFailureHost = (id)[previewBridge startCameraEffectsPreview];
        Check(retryFailureHost != nil, @"a failed-retry fixture creates a preview host");
        retryFailureHost.resizeRenderer(retryFailureHost.bounds); retryFailureHost.reconcileRenderer(YES);
        DrainMainQueue();
        previewState = [NSJSONSerialization JSONObjectWithData:[previewBridge cameraEffectsSnapshot] options:0 error:nil];
        Check(helper.starts == startsBeforeNormalization + 2 && helper.stops == stopsBeforeNormalization + 2 &&
              [previewBridge valueForKey:@"cameraPreviewHost"] == nil && [previewState[@"previewError"] length] > 0,
              @"WrongUsage after the single retry remains an error and never becomes preview success");

        startsBeforeNormalization = helper.starts; stopsBeforeNormalization = helper.stops;
        helper.startResults = [@[@(ZoomSDKError_WrongUsage), @(ZoomSDKError_Success)] mutableCopy];
        __weak CameraTestHelper *weakHelper = helper;
        helper.onStop = ^{
            weakHelper.onStop = cleanupStopAssertion;
            [weakPreviewBridge closeCameraEffects];
        };
        WHZoomRenderHost *cancelledNormalizationHost = (id)[previewBridge startCameraEffectsPreview];
        Check(cancelledNormalizationHost != nil, @"a normalization cancellation fixture creates a preview host");
        cancelledNormalizationHost.resizeRenderer(cancelledNormalizationHost.bounds); cancelledNormalizationHost.reconcileRenderer(YES);
        DrainMainQueue();
        Check(helper.starts == startsBeforeNormalization + 1 && helper.stops == stopsBeforeNormalization + 2 &&
              [previewBridge valueForKey:@"cameraPreviewHost"] == nil && !previewBridge.cameraEffectsReady,
              @"closing settings in a synchronous normalization stop callback prevents its late retry");
        helper.startResults = nil;
        Check([previewBridge prepareCameraEffectsWithJWT:@"normalized-preview-fixture" completion:^(NSInteger code, NSString *message) {
            Check(code == 0, @"settings can authorize after normalization was cancelled");
        }] == 0, @"the fixture reacquires the SDK after normalization cancellation");
        [previewBridge onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        NSUInteger completedHelperStarts = helper.starts;

        // Real meetings use their normal self-view. Settings must not create
        // a second camera preview or disturb an active meeting's media.
        [previewBridge setValue:@NO forKey:@"cameraSettingsOnly"];
        [previewBridge setValue:@"meeting-preview-fixture" forKey:@"sessionID"];
        [previewBridge setValue:@YES forKey:@"hasEnteredMeeting"];
        fixtureRendererReady = NO;
        NSUInteger helperStops = helper.stops;
        cameraCommands = fixtureSDK.meeting.action.unmutes + fixtureSDK.meeting.action.mutes;
        Check([previewBridge startCameraEffectsPreview] == nil && previewBridge.cameraEffectsError.length > 0 &&
              fixtureSDK.meeting.container.creations == creations && helper.starts == completedHelperStarts && helper.stops == helperStops,
              @"an in-meeting preview is rejected without creating an element or changing the camera helper");
        [previewBridge setValue:@YES forKey:@"cameraSettingsOnly"];
        Check([previewBridge startCameraEffectsPreview] == nil && helper.starts == completedHelperStarts,
              @"a meeting session also blocks preview during a settings-to-meeting handoff");
        [previewBridge setValue:@NO forKey:@"cameraSettingsOnly"];
        staleHelperMount(YES);
        DrainMainQueue();
        Check(helper.starts == completedHelperStarts && fixtureSDK.meeting.container.creations == creations,
              @"a stale standalone host cannot activate capture after entering a meeting");
        uninitializations = fixtureSDK.uninitializations;
        [previewBridge closeCameraEffects];
        Check(helper.stops == helperStops && fixtureSDK.uninitializations == uninitializations && fixtureSDK.meeting.leaves == 0 &&
              fixtureSDK.meeting.action.unmutes + fixtureSDK.meeting.action.mutes == cameraCommands,
              @"closing in-meeting settings never stops a helper, mutes video, leaves, or uninitializes the meeting");
        [previewBridge setValue:nil forKey:@"sessionID"]; [previewBridge setValue:@YES forKey:@"cameraSettingsOnly"];
        [previewBridge closeCameraEffects];

        // Process termination can arrive during browser auth or while the menu
        // bar has a settings-only SDK owner. Cleanup must finish synchronously.
        NSUInteger initializations = fixtureSDK.initializations;
        uninitializations = fixtureSDK.uninitializations;
        WHZoomSDKBridge *unused = [WHZoomSDKBridge new];
        Check([unused shutdown] && [unused shutdown], @"unused and repeated shutdown both confirm completion");
        Check(fixtureSDK.initializations == initializations && fixtureSDK.uninitializations == uninitializations,
              @"terminating an unused bridge never initializes or uninitializes Zoom");

        fixtureSDK.meeting.status = ZoomSDKMeetingStatus_Idle;
        WHZoomSDKBridge *pendingQuit = [WHZoomSDKBridge new];
        __block NSUInteger quitCompletions = 0;
        Check([pendingQuit prepareCameraEffectsWithJWT:@"pending-quit-fixture" completion:^(NSInteger code, NSString *message) {
            quitCompletions++; Check(code != 0, @"termination cancels outstanding authorization");
        }] == 0, @"pending quit starts settings-only authorization");
        pendingQuit.eventHandler = ^(NSString *session, NSString *event, NSData *data) { Check(NO, @"quit cannot present meeting events"); };
        pendingQuit.cameraEffectsChanged = ^(NSData *data) { Check(NO, @"quit cannot update camera UI"); };
        pendingQuit.mediaDevicesChanged = ^(NSData *data) { Check(NO, @"quit cannot update media UI"); };
        [pendingQuit shutdown]; [pendingQuit shutdown];
        [pendingQuit onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        DrainMainQueue();
        Check(quitCompletions == 1 && fixtureSDK.uninitializations == uninitializations + 1 &&
              !pendingQuit.cameraEffectsReady && fixtureSDK.auth.delegate == nil,
              @"quit uninitializes pending authorization once and ignores late auth callbacks");
        initializations = fixtureSDK.initializations;
        Check([pendingQuit prepareCameraEffectsWithJWT:@"late-fixture" completion:^(NSInteger code, NSString *message) {
            Check(NO, @"a rejected request cannot complete authorization");
        }] != 0 && [pendingQuit beginRoomShareWithJWT:@"late-fixture" sessionID:@"late"] != 0 &&
              fixtureSDK.initializations == initializations,
              @"a terminated bridge cannot initialize again through settings or meeting entry points");

        CameraGateBridge *readyQuit = [CameraGateBridge new]; readyQuit.operations = [NSMutableArray array];
        Check([readyQuit prepareCameraEffectsWithJWT:@"ready-quit-fixture" completion:^(NSInteger code, NSString *message) {
            Check(code == 0, @"ready quit fixture authorizes settings");
        }] == 0, @"a new owner can initialize after the old owner terminated");
        [readyQuit onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        helper.onStop = nil; fixtureRendererReady = YES;
        WHZoomRenderHost *quitHost = (id)[readyQuit startCameraEffectsPreview];
        Check(quitHost != nil, @"ready quit has a deferred camera preview");
        void (^quitMount)(BOOL) = [quitHost.reconcileRenderer copy];
        NSUInteger startsBeforeQuit = helper.starts;
        quitMount(YES);
        uninitializations = fixtureSDK.uninitializations;
        [readyQuit shutdown];
        quitMount(YES); [pendingQuit onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        DrainMainQueue();
        Check(helper.starts == startsBeforeQuit && fixtureSDK.uninitializations == uninitializations + 1 &&
              !readyQuit.cameraEffectsReady && [readyQuit valueForKey:@"cameraPreviewHost"] == nil &&
              fixtureSDK.settings.video.delegate == nil && fixtureSDK.settings.background.delegate == nil,
              @"quit detaches settings and cancels deferred preview before SDK teardown");

        CameraGateBridge *meetingQuit = [CameraGateBridge new]; meetingQuit.operations = [NSMutableArray array];
        Check([meetingQuit prepareCameraEffectsWithJWT:@"active-quit-fixture" completion:^(NSInteger code, NSString *message) {
            Check(code == 0, @"active quit fixture authorizes");
        }] == 0, @"active quit fixture acquires the SDK");
        [meetingQuit onZoomSDKAuthReturn:ZoomSDKAuthError_Success];
        [meetingQuit setValue:@NO forKey:@"cameraSettingsOnly"];
        [meetingQuit setValue:@"active-quit" forKey:@"sessionID"];
        fixtureSDK.meeting.status = ZoomSDKMeetingStatus_InMeeting;
        uninitializations = fixtureSDK.uninitializations;
        Check(![meetingQuit shutdown], @"the caller is told that active meeting cleanup was refused");
        Check(fixtureSDK.uninitializations == uninitializations && meetingQuit.cameraEffectsReady,
              @"terminal cleanup refuses to tear down an active meeting");
        fixtureSDK.meeting.status = ZoomSDKMeetingStatus_Ended;
        Check([meetingQuit shutdown] && [meetingQuit shutdown], @"ended meeting cleanup confirms completion");
        Check(fixtureSDK.uninitializations == uninitializations + 1 && !meetingQuit.cameraEffectsReady && fixtureSDK.meeting.leaves == 0,
              @"confirmed meeting end allows exactly one synchronous teardown without an extra leave");

        class_replaceMethod(previewMetaClass, @selector(alloc), originalPreviewAllocator, allocatorTypes);
        method_setImplementation(authorization, originalAuthorization);
        method_setImplementation(readiness, originalReadiness);

        method_setImplementation(shared, original);
        puts("PASS: inert auth/cancellation, effect readback, photo identity, deferred preview, and synchronous terminal shutdown");
    }
    return 0;
}
