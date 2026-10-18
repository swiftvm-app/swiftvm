#import "GuestDisplayBridge.h"
#import "CocoaSpice.h"
#import "CSSession+Protected.h"
@import CocoaSpiceRenderer;
@import MetalKit;
@import QuartzCore;
#include <gst/gst.h>

// Windows sound goes through QEMU's CoreAudio device. SPICE carries local surfaces, with streaming
// video disabled, so it needs no statically registered GStreamer audio or video plugins.
void gst_ios_init(void) { gst_init(NULL, NULL); }

// An MTKView that says when it moves to another window, or out of one.
@interface SVMMetalView : MTKView
@property (nonatomic, copy) void (^movedToWindow)(void);
@end

@implementation SVMMetalView
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.movedToWindow) self.movedToWindow();
}
@end

@class SVMSpiceRegion;

@interface SVMSpiceDisplay : NSObject <SVMGuestDisplay, CSConnectionDelegate, MTKViewDelegate>
@property (nonatomic, strong) SVMMetalView *metalView;
@property (nonatomic, strong) NSHashTable<SVMSpiceRegion *> *regions;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CSMetalRenderer *renderer;
@property (nonatomic, strong) CSConnection *connection;
@property (nonatomic, strong) CSDisplay *display;
@property (nonatomic, strong) CSInput *input;
@property (nonatomic, copy) void (^connected)(NSError *error);
@property (nonatomic, copy) void (^disconnected)(NSString *reason);
@property (nonatomic, copy) void (^resized)(CGSize size);
@property (nonatomic) BOOL closed;
@property (nonatomic) BOOL didConnect;
@property (nonatomic) BOOL canResize;
@property (nonatomic) CGSize requestedSize;
@property (nonatomic) CGSize sentSize;
@property (nonatomic) uint8_t buttons;
@end

// A view of part of the display: a renderer of its own on the same display, which draws the display
// so that only the region falls into its view. A window of one Windows app on the Mac is one.
@interface SVMSpiceRegion : NSObject <SVMGuestDisplayRegion, MTKViewDelegate>
@property (nonatomic, strong) SVMMetalView *metalView;
@property (nonatomic, strong) CSMetalRenderer *renderer;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, weak) SVMSpiceDisplay *owner;
@property (nonatomic) BOOL closed;
- (instancetype)initWithOwner:(SVMSpiceDisplay *)owner;
- (void)show:(CSDisplay *)display;
- (void)updateViewport;
@end

@implementation SVMSpiceRegion {
    CGRect _region;
}

- (instancetype)initWithOwner:(SVMSpiceDisplay *)owner {
    if (!(self = [super init])) return nil;
    _owner = owner;
    // A display draws with the device of its first renderer, and with none other.
    _metalView = [[SVMMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480) device:owner.metalView.device];
    _metalView.paused = YES;
    _metalView.enableSetNeedsDisplay = NO;
    // What the guest has behind its windows, which the renderer draws as nothing, shows what is
    // behind the view.
    _metalView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _metalView.layer.opaque = NO;
    __weak SVMSpiceRegion *weakSelf = self;
    _metalView.movedToWindow = ^{ [weakSelf viewMovedToWindow]; };
    _renderer = [[CSMetalRenderer alloc] initWithMetalKitView:_metalView];
    [_renderer changeUpscaler:MTLSamplerMinMagFilterNearest downscaler:MTLSamplerMinMagFilterLinear];
    _metalView.delegate = self;
    return self;
}

- (NSView *)view { return self.metalView; }

- (CGRect)region { return _region; }

- (void)setRegion:(CGRect)region {
    _region = region;
    [self updateViewport];
}

- (void)show:(CSDisplay *)display {
    if (self.closed) return;
    [display addRenderer:self.renderer];
    [self updateViewport];
}

- (void)viewMovedToWindow {
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (!self.metalView.window || self.closed) return;
    self.displayLink = [self.metalView displayLinkWithTarget:self selector:@selector(drawFrame:)];
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    CSDisplay *display = self.owner.display;
    if (display) [self.renderer invalidateRenderSource:display withCompletion:nil];
}

- (void)drawFrame:(CADisplayLink *)link { [self.metalView draw]; }

// The renderer puts the middle of the display in the middle of the view, moved by the origin: to the
// right by its x, and down by its y. The middle of the region goes there instead, at the scale that
// fits the region in.
- (void)updateViewport {
    CGSize size = self.owner.display.displaySize;
    CGSize drawable = self.metalView.drawableSize;
    if (size.width <= 0 || size.height <= 0 || drawable.width <= 0 || drawable.height <= 0) return;
    CGRect shown = CGRectIsEmpty(_region) ? (CGRect){CGPointZero, size} : _region;
    CGFloat scale = MIN(drawable.width / shown.size.width, drawable.height / shown.size.height);
    self.renderer.viewportScale = scale;
    self.renderer.viewportOrigin = CGPointMake((size.width / 2 - CGRectGetMidX(shown)) * scale,
                                               (size.height / 2 - CGRectGetMidY(shown)) * scale);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self.renderer mtkView:view drawableSizeWillChange:size];
    [self updateViewport];
}
- (void)drawInMTKView:(MTKView *)view { [self.renderer drawInMTKView:view]; }

- (void)close {
    if (self.closed) return;
    self.closed = YES;
    [self.owner.display removeRenderer:self.renderer];
    [self.owner.regions removeObject:self];
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.metalView.movedToWindow = nil;
    self.metalView.delegate = nil;
}
@end

@implementation SVMSpiceDisplay

- (instancetype)initWithSocket:(NSURL *)socket {
    if (!(self = [super init])) return nil;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || ![CSMain.sharedInstance spiceStart]) return nil;
    _metalView = [[SVMMetalView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768) device:device];
    // MTKView's own timer never restarts once its view has left a window, so a machine's window
    // that was closed and opened again stayed on its last frame. A display link of the view's
    // window draws instead, made anew whenever the view moves into one.
    _metalView.paused = YES;
    _metalView.enableSetNeedsDisplay = NO;
    __weak SVMSpiceDisplay *weakSelf = self;
    _metalView.movedToWindow = ^{ [weakSelf viewMovedToWindow]; };
    _metalView.clearColor = MTLClearColorMake(0, 0, 0, 1);
    _renderer = [[CSMetalRenderer alloc] initWithMetalKitView:_metalView];
    [_renderer changeUpscaler:MTLSamplerMinMagFilterNearest downscaler:MTLSamplerMinMagFilterLinear];
    _metalView.delegate = self;
    _regions = [NSHashTable weakObjectsHashTable];
    _connection = [[CSConnection alloc] initWithUnixSocketFile:socket];
    // The client renders shared surfaces with Metal. SPICE otherwise enables this capability only
    // when built with its GTK/EGL renderer, which this app does not use.
    g_object_set(_connection.session.session, "gl-scanout", TRUE, NULL);
    _connection.session.shareClipboard = NO;
    _connection.audioEnabled = NO;
    _connection.delegate = self;
    return self;
}

- (NSView *)view { return self.metalView; }

- (id<SVMGuestDisplayRegion>)makeRegion {
    if (self.closed) return nil;
    SVMSpiceRegion *region = [[SVMSpiceRegion alloc] initWithOwner:self];
    [self.regions addObject:region];
    if (self.display) [region show:self.display];
    return region;
}

- (void)viewMovedToWindow {
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (!self.metalView.window || self.closed) return;
    self.displayLink = [self.metalView displayLinkWithTarget:self selector:@selector(drawFrame:)];
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    // The new window shows nothing until the next frame, which an idle guest doesn't send.
    if (self.display) [self.renderer invalidateRenderSource:self.display withCompletion:nil];
}

- (void)drawFrame:(CADisplayLink *)link { [self.metalView draw]; }

- (void)connect {
    if (![self.connection connect]) {
        [self finishConnecting:[NSError errorWithDomain:@"SwiftVM.GuestDisplay" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"The machine's display couldn't connect."
        }]];
    }
}

- (void)finishConnecting:(NSError *)error {
    if (self.closed || self.didConnect) return;
    self.didConnect = YES;
    if (self.connected) self.connected(error);
}

- (void)close {
    if (self.closed) return;
    self.closed = YES;
    self.connected = nil;
    self.disconnected = nil;
    self.resized = nil;
    [self.input releaseKeys];
    for (SVMSpiceRegion *region in self.regions.allObjects) [region close];
    [self.display removeRenderer:self.renderer];
    [self.connection disconnect];
    self.connection.delegate = nil;
    // The link holds on to this display; it goes first.
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.metalView.movedToWindow = nil;
    self.metalView.delegate = nil;
    self.display = nil;
    self.input = nil;
}

- (void)updateDisplay {
    CGSize size = self.display.displaySize;
    if (size.width <= 0 || size.height <= 0) return;
    CGSize drawable = self.metalView.drawableSize;
    self.renderer.viewportScale = MIN(drawable.width / size.width, drawable.height / size.height);
    for (SVMSpiceRegion *region in self.regions.allObjects) [region updateViewport];
    if (self.resized) self.resized(size);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self.renderer mtkView:view drawableSizeWillChange:size];
    [self updateDisplay];
}
- (void)drawInMTKView:(MTKView *)view { [self.renderer drawInMTKView:view]; }

- (void)key:(uint16_t)scancode down:(BOOL)down {
    CSInputKey action = down ? kCSInputKeyPress : kCSInputKeyRelease;
    // PCKeys uses QEMU's bit 7 for extended keys; SPICE uses bit 8 and a separate Pause sequence.
    if (scancode == 0xC6) {
        [self.input sendPause:action];
    } else {
        int code = (scancode & 0x80) ? 0x100 | (scancode & 0x7F) : scancode;
        [self.input sendKey:action code:code];
    }
}

- (void)pointerAt:(CGPoint)point buttons:(uint8_t)buttons {
    CSInputButton mask = buttons & 7;
    [self.input sendMousePosition:mask absolutePoint:point];
    [self.display.cursor moveTo:point];
    // SPICE buttons 6 and 7 are horizontal wheel events despite CocoaSpice's side-button names.
    for (int bit = 0; bit < 7; bit++) {
        uint8_t button = 1 << bit;
        if ((self.buttons ^ buttons) & button) {
            [self.input sendMouseButton:button mask:mask pressed:(buttons & button) != 0];
        }
    }
    self.buttons = buttons;
}

- (void)requestSize:(CGSize)size {
    self.requestedSize = size;
    [self sendRequestedSize];
}

- (void)sendRequestedSize {
    if (!self.canResize || !self.display || self.requestedSize.width <= 0 ||
        CGSizeEqualToSize(self.requestedSize, self.sentSize)) return;
    // QEMU announces the monitor on scanout buffer changes too. A frame must not trigger another
    // Windows mode switch; send only a new host size, or resend when the guest agent reconnects.
    self.sentSize = self.requestedSize;
    [self.display requestResolution:(CGRect){CGPointZero, self.requestedSize}];
}

- (void)screenshot:(void (^)(NSData *))completion {
    if (!self.display || self.closed) { completion(nil); return; }
    [self.display screenshotWithCompletion:^(CSScreenshot *shot) {
        NSBitmapImageRep *bitmap = shot ? [[NSBitmapImageRep alloc] initWithData:shot.image.TIFFRepresentation] : nil;
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(png); });
    }];
}

// CocoaSpice calls delegates on its event-loop thread. AppKit and the app's state only see callbacks
// on the main thread, and closing a window never closes the connection owned by the running VM.
- (void)spiceConnected:(CSConnection *)connection {
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishConnecting:nil]; });
}
- (void)spiceDisconnected:(CSConnection *)connection {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.closed && self.disconnected) self.disconnected(@"The machine's display disconnected.");
    });
}
- (void)spiceInputAvailable:(CSConnection *)connection input:(CSInput *)input {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed) return;
        self.input = input;
        [input requestMouseMode:NO];
    });
}
- (void)spiceInputUnavailable:(CSConnection *)connection input:(CSInput *)input {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.input == input) self.input = nil; });
}
- (void)spiceError:(CSConnection *)connection code:(CSConnectionError)code message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed) return;
        NSString *reason = message ?: @"The connection to the machine's display failed.";
        if (!self.didConnect) {
            [self finishConnecting:[NSError errorWithDomain:@"SwiftVM.GuestDisplay" code:code userInfo:@{NSLocalizedDescriptionKey: reason}]];
        } else if (self.disconnected) self.disconnected(reason);
    });
}
- (void)spiceDisplayCreated:(CSConnection *)connection display:(CSDisplay *)display {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed || !display.isPrimaryDisplay) return;
        self.display = display;
        self.sentSize = CGSizeZero;
        [display addRenderer:self.renderer];
        for (SVMSpiceRegion *region in self.regions.allObjects) [region show:display];
        [self updateDisplay];
        [self sendRequestedSize];
    });
}
- (void)spiceDisplayUpdated:(CSConnection *)connection display:(CSDisplay *)display {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.closed && self.display == display) [self updateDisplay]; });
}
- (void)spiceDisplayDestroyed:(CSConnection *)connection display:(CSDisplay *)display {
    dispatch_async(dispatch_get_main_queue(), ^{
        [display removeRenderer:self.renderer];
        for (SVMSpiceRegion *region in self.regions.allObjects) [display removeRenderer:region.renderer];
        if (self.display == display) self.display = nil;
    });
}
- (void)spiceAgentConnected:(CSConnection *)connection supportingFeatures:(CSConnectionAgentFeature)features {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed) return;
        self.canResize = (features & kCSConnectionAgentFeatureMonitorsConfig) != 0;
        [self sendRequestedSize];
    });
}
- (void)spiceAgentDisconnected:(CSConnection *)connection {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.canResize = NO;
        self.sentSize = CGSizeZero;
    });
}
- (void)spiceForwardedPortOpened:(CSConnection *)connection port:(CSPort *)port {}
- (void)spiceForwardedPortClosed:(CSConnection *)connection port:(CSPort *)port {}
@end

__attribute__((visibility("default"))) id<SVMGuestDisplay> SVMCreateSpiceDisplay(NSURL *socket) {
    return [[SVMSpiceDisplay alloc] initWithSocket:socket];
}
