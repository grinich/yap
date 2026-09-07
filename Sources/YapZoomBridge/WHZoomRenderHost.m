#import "WHZoomRenderHost.h"
#import <math.h>
#import <os/log.h>

static BOOL WHZoomRendererBoundsEqual(NSRect first, NSRect second) {
    // AppKit bounds scaling can introduce sub-pixel floating-point residue.
    // Compare against the last delivered frame; never round the frame sent to Zoom.
    const CGFloat tolerance = 0.001;
    return fabs(first.origin.x - second.origin.x) <= tolerance &&
        fabs(first.origin.y - second.origin.y) <= tolerance &&
        fabs(first.size.width - second.size.width) <= tolerance &&
        fabs(first.size.height - second.size.height) <= tolerance;
}

@interface WHZoomRenderHost ()
@property(nonatomic) BOOL rendererUpdateScheduled;
@property(nonatomic) NSRect lastRendererBounds;
@property(nonatomic) BOOL hasRendererGeometry;
@property(nonatomic, weak) NSWindow *observedRendererWindow;
@property(nonatomic, strong) NSHashTable<NSView *> *observedRendererAncestors;
@property(nonatomic, copy) NSString *lastVisibilityDiagnostic;
@end

@implementation WHZoomRenderHost
@synthesize resizeRenderer = _resizeRenderer;
- (void)setResizeRenderer:(void (^)(NSRect))resizeRenderer {
    if (_resizeRenderer == resizeRenderer) return;
    _resizeRenderer = [resizeRenderer copy];
    // Geometry belongs to the renderer, not the current window or visibility.
    // A replacement renderer still needs its first usable bounds delivered.
    self.hasRendererGeometry = NO;
    if (_resizeRenderer) [self scheduleRendererUpdate];
}
- (BOOL)isRendererWindowVisible {
    NSWindow *window = self.window;
    // Occlusion is an optimization hint, not proof that our video is hidden.
    // It can remain unset for an ordered, visibly drawn native meeting window.
    // Keep renderers subscribed while the window and tile remain usable.
    return window != nil && window.visible && !window.miniaturized;
}
- (BOOL)isReadyForRenderer {
    NSRect visible = NSIntersectionRect(self.bounds, self.visibleRect);
    return [self isRendererWindowVisible] && !self.hiddenOrHasHiddenAncestor &&
        isfinite(self.bounds.size.width) && isfinite(self.bounds.size.height) &&
        self.bounds.size.width >= 1 && self.bounds.size.height >= 1 &&
        isfinite(visible.size.width) && isfinite(visible.size.height) &&
        visible.size.width >= 1 && visible.size.height >= 1;
}
- (void)updateRendererVisibilityObservers {
    NSMutableArray<NSView *> *ancestors = [NSMutableArray array];
    for (NSView *view = self.superview; view; view = view.superview) [ancestors addObject:view];
    BOOL unchanged = self.observedRendererAncestors != nil &&
        self.observedRendererWindow == self.window && self.observedRendererAncestors.count == ancestors.count;
    if (unchanged) for (NSView *view in ancestors) {
        if (![self.observedRendererAncestors containsObject:view]) { unchanged = NO; break; }
    }
    if (unchanged) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    self.observedRendererAncestors = NSHashTable.weakObjectsHashTable;
    self.observedRendererWindow = self.window;
    // Use the actual hierarchy, rather than assuming SwiftUI uses NSScrollView.
    // Both ancestor scrolling and ancestor layout can change visibleRect without
    // changing this host's own size. Notification delivery is coalesced below.
    for (NSView *view in ancestors) {
        [self.observedRendererAncestors addObject:view];
        view.postsBoundsChangedNotifications = YES;
        view.postsFrameChangedNotifications = YES;
        [center addObserver:self selector:@selector(rendererVisibilityDidChange:)
                       name:NSViewBoundsDidChangeNotification object:view];
        [center addObserver:self selector:@selector(rendererVisibilityDidChange:)
                       name:NSViewFrameDidChangeNotification object:view];
    }
    if (self.window) for (NSNotificationName name in @[
        NSWindowDidChangeOcclusionStateNotification, NSWindowDidMiniaturizeNotification,
        NSWindowDidDeminiaturizeNotification, NSWindowDidExposeNotification
    ]) {
        [center addObserver:self selector:@selector(rendererVisibilityDidChange:) name:name object:self.window];
    }
}
- (void)rendererVisibilityDidChange:(NSNotification *)notification {
    [self scheduleRendererUpdate];
}
- (void)scheduleRendererUpdate {
    if (self.rendererUpdateScheduled) return;
    self.rendererUpdateScheduled = YES;
    __weak typeof(self) weakSelf = self;
    // SwiftUI can attach a zero-sized view, then lay it out in the same turn.
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        self.rendererUpdateScheduled = NO;
        [self updateRendererVisibilityObservers];
        BOOL ready = self.isReadyForRenderer;
        NSRect visible = NSIntersectionRect(self.bounds, self.visibleRect);
        // AppKit can use effectively unbounded rectangles during attachment.
        // Diagnostics need useful dimensions, not hundreds of DBL_MAX digits.
        CGFloat clippedWidth = isfinite(visible.size.width) ? fmin(fmax(visible.size.width, 0), 99999) : 0;
        CGFloat clippedHeight = isfinite(visible.size.height) ? fmin(fmax(visible.size.height, 0), 99999) : 0;
        NSString *diagnostic = [NSString stringWithFormat:@"window=%d visible=%d occluded=%d mini=%d hidden=%d ready=%d bounds=%.0fx%.0f clipped=%.0fx%.0f",
            self.window != nil, self.window.visible,
            (self.window.occlusionState & NSWindowOcclusionStateVisible) == 0,
            self.window.miniaturized, self.hiddenOrHasHiddenAncestor, ready,
            self.bounds.size.width, self.bounds.size.height, clippedWidth, clippedHeight];
        if (![self.lastVisibilityDiagnostic isEqualToString:diagnostic]) {
            self.lastVisibilityDiagnostic = diagnostic;
            static os_log_t log;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ log = os_log_create("app.yap.zoom", "render-visibility"); });
            os_log_info(log, "%{public}@", diagnostic);
        }
        if (ready && self.resizeRenderer && (!self.hasRendererGeometry || !WHZoomRendererBoundsEqual(self.lastRendererBounds, self.bounds))) {
            self.hasRendererGeometry = YES;
            self.lastRendererBounds = self.bounds;
            self.resizeRenderer(self.bounds);
        }
        // Retain delivered logical geometry during clipping, hiding and reparenting.
        // Reapplying an identical frame can disturb a live SDK render surface.
        if (self.reconcileRenderer) self.reconcileRenderer(ready);
    });
}
- (void)layout { [super layout]; [self scheduleRendererUpdate]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self scheduleRendererUpdate]; }
- (void)setFrameOrigin:(NSPoint)origin { [super setFrameOrigin:origin]; [self scheduleRendererUpdate]; }
- (void)setBoundsSize:(NSSize)size { [super setBoundsSize:size]; [self scheduleRendererUpdate]; }
- (void)setBoundsOrigin:(NSPoint)origin { [super setBoundsOrigin:origin]; [self scheduleRendererUpdate]; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self scheduleRendererUpdate];
}
- (void)viewDidMoveToSuperview { [super viewDidMoveToSuperview]; [self scheduleRendererUpdate]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; [self scheduleRendererUpdate]; }
- (void)viewDidHide { [super viewDidHide]; [self scheduleRendererUpdate]; }
- (void)viewDidUnhide { [super viewDidUnhide]; [self scheduleRendererUpdate]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
