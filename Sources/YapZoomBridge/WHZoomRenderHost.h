#import <AppKit/AppKit.h>

/// Zoom owns the renderer; this host forwards only usable AppKit geometry.
@interface WHZoomRenderHost : NSView
@property(nonatomic, copy) void (^resizeRenderer)(NSRect);
@property(nonatomic, copy) void (^reconcileRenderer)(BOOL);
@property(nonatomic, readonly) BOOL isReadyForRenderer;
- (void)scheduleRendererUpdate;
@end
