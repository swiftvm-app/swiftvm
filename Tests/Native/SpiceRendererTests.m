#import <Foundation/Foundation.h>
#import "CSRenderer.h"
#import "CSRenderSource.h"
#import "CSMetalRenderer.h"

// Exercise the real renderer's scheduling without a window, guest, shaders, or GPU commands.
@interface TestSource : NSObject <CSRenderSource>
@property (nonatomic) BOOL isVisible;
@property (nonatomic) CGPoint offset;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic) NSUInteger numVertices;
@property (nonatomic, strong) id<MTLBuffer> vertices;
@property (nonatomic) BOOL hasAlpha;
@property (nonatomic) BOOL isInverted;
@property (nonatomic, weak) id<CSRenderSource> cursorSource;
@end
@implementation TestSource
@end

@interface TestView : NSObject
@property (nonatomic) BOOL hasDescriptor;
@property (nonatomic) BOOL hasDrawable;
@property (nonatomic) NSUInteger descriptorRequests;
@property (nonatomic) NSUInteger drawableRequests;
@end
@implementation TestView
- (MTLRenderPassDescriptor *)currentRenderPassDescriptor {
    self.descriptorRequests++;
    return self.hasDescriptor ? [MTLRenderPassDescriptor renderPassDescriptor] : nil;
}
- (id<CAMetalDrawable>)currentDrawable {
    self.drawableRequests++;
    return self.hasDrawable ? (id<CAMetalDrawable>)[NSObject new] : nil;
}
@end

@interface TestCommands : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) void (^completion)(id<MTLCommandBuffer>);
@property (nonatomic) NSUInteger presentations;
@property (nonatomic) NSUInteger commits;
@end
@implementation TestCommands
- (void)presentDrawable:(id<MTLDrawable>)drawable { self.presentations++; }
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))completion { self.completion = completion; }
- (void)commit { self.commits++; }
- (void)complete {
    void (^completion)(id<MTLCommandBuffer>) = self.completion;
    self.completion = nil;
    if (completion) completion((id<MTLCommandBuffer>)self);
}
@end

@interface TestQueue : NSObject
@property (nonatomic, strong) TestCommands *commands;
@end
@implementation TestQueue
- (id<MTLCommandBuffer>)commandBuffer { return (id<MTLCommandBuffer>)self.commands; }
@end

@interface TestRenderer : CSMetalRenderer
@property (nonatomic) NSUInteger renders;
@end
@implementation TestRenderer
- (BOOL)_renderCommand:(id<MTLCommandBuffer>)commandBuffer
            drawSource:(id<CSRenderSource>)source
        viewportOrigin:(CGPoint)origin
         viewportScale:(CGFloat)scale
          viewportSize:(vector_uint2)size
               sampler:(id<MTLSamplerState>)sampler
  renderPassDescriptor:(MTLRenderPassDescriptor *)descriptor {
    self.renders++;
    return YES;
}
@end

static NSUInteger failures;
static void check(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

static void drainMainQueue(void) {
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    while (!finished) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
}

static TestRenderer *makeRenderer(TestCommands *commands) {
    TestQueue *queue = [TestQueue new];
    queue.commands = commands;
    TestRenderer *renderer = [TestRenderer new];
    // Skip pipeline initialization; retain the real dirty-state and completion implementation.
    [renderer setValue:queue forKey:@"commandQueue"];
    [renderer setValue:[NSMutableArray array] forKey:@"renderCompletions"];
    return renderer;
}

static TestSource *makeSource(void) {
    TestSource *source = [TestSource new];
    source.isVisible = YES;
    source.texture = (id<MTLTexture>)[NSObject new];
    source.vertices = (id<MTLBuffer>)[NSObject new];
    return source;
}

static void idleResize(void) {
    TestCommands *commands = [TestCommands new];
    TestRenderer *renderer = makeRenderer(commands);
    TestView *view = [TestView new];
    view.hasDescriptor = view.hasDrawable = YES;
    [renderer invalidateRenderSource:makeSource() withCompletion:nil];
    drainMainQueue();
    [renderer drawInMTKView:(MTKView *)view];
    [commands complete];
    drainMainQueue();
    check(commands.commits == 1 && commands.presentations == 1, "first dirty frame is submitted");

    NSUInteger requests = view.drawableRequests;
    [renderer drawInMTKView:(MTKView *)view];
    check(view.drawableRequests == requests && view.descriptorRequests == requests,
          "a clean frame does not acquire drawable textures");

    // No new guest frame or scale/origin change accompanies this backing-size change.
    [renderer mtkView:(MTKView *)view drawableSizeWillChange:CGSizeMake(1600, 1100)];
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 2 && commands.commits == 2 && commands.presentations == 2,
          "an idle drawable-size change submits a new frame");
    [commands complete];
    drainMainQueue();
    requests = view.drawableRequests;
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 2 && view.drawableRequests == requests,
          "the resize invalidation is consumed exactly once");
}

static void unavailableDrawable(BOOL descriptor, BOOL drawable) {
    TestCommands *commands = [TestCommands new];
    TestRenderer *renderer = makeRenderer(commands);
    TestView *view = [TestView new];
    view.hasDescriptor = descriptor;
    view.hasDrawable = drawable;
    __block NSUInteger completions = 0;
    [renderer invalidateRenderSource:makeSource() withCompletion:^{ completions++; }];
    drainMainQueue();
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 0 && commands.commits == 0 && completions == 0,
          "a dirty frame without drawable textures waits without acknowledging it");

    view.hasDescriptor = view.hasDrawable = YES;
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 1 && commands.commits == 1 && completions == 0,
          "drawable recovery retries the pending frame before completing it");
    // The submitted frame is clean, but its GPU work still owns the completion.
    view.hasDescriptor = descriptor;
    view.hasDrawable = drawable;
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 1 && commands.commits == 1 && completions == 0,
          "a clean draw without drawable textures does not complete in-flight GPU work");
    [commands complete];
    drainMainQueue();
    check(completions == 1, "the submitted frame completes once");
    view.hasDescriptor = view.hasDrawable = YES;
    [renderer drawInMTKView:(MTKView *)view];
    check(completions == 1 && commands.commits == 1, "clean draws neither resubmit nor complete twice");
}

static void unavailableCommandBuffer(void) {
    TestRenderer *renderer = makeRenderer(nil);
    TestQueue *queue = [renderer valueForKey:@"commandQueue"];
    TestView *view = [TestView new];
    view.hasDescriptor = view.hasDrawable = YES;
    __block NSUInteger completions = 0;
    [renderer invalidateRenderSource:makeSource() withCompletion:^{ completions++; }];
    drainMainQueue();
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 0 && completions == 0, "a missing command buffer preserves pending work");

    TestCommands *commands = [TestCommands new];
    queue.commands = commands;
    [renderer drawInMTKView:(MTKView *)view];
    check(renderer.renders == 1 && commands.commits == 1 && completions == 0,
          "command-buffer recovery retries the pending frame");
    [commands complete];
    drainMainQueue();
    check(completions == 1, "command-buffer recovery completes the frame exactly once");
}

static void frameCompletions(BOOL submitNextFrame) {
    TestCommands *first = [TestCommands new];
    TestCommands *second = [TestCommands new];
    TestRenderer *renderer = makeRenderer(first);
    TestQueue *queue = [renderer valueForKey:@"commandQueue"];
    TestView *view = [TestView new];
    view.hasDescriptor = view.hasDrawable = YES;
    __block NSUInteger firstCompletions = 0, secondCompletions = 0;
    [renderer invalidateRenderSource:makeSource() withCompletion:^{ firstCompletions++; }];
    drainMainQueue();
    [renderer drawInMTKView:(MTKView *)view];
    [renderer drawInMTKView:(MTKView *)view];
    check(firstCompletions == 0, "a clean draw with drawable textures does not acknowledge in-flight work");

    [renderer invalidateRenderSource:makeSource() withCompletion:^{ secondCompletions++; }];
    drainMainQueue();
    queue.commands = second;
    if (submitNextFrame) [renderer drawInMTKView:(MTKView *)view];
    [first complete];
    drainMainQueue();
    check(firstCompletions == 1 && secondCompletions == 0,
          "a GPU completion acknowledges only its own frame, not a later pending or submitted frame");

    if (!submitNextFrame) [renderer drawInMTKView:(MTKView *)view];
    [renderer disableRender];
    drainMainQueue();
    [renderer drawInMTKView:(MTKView *)view];
    check(secondCompletions == 0, "removing the source does not release a submitted frame early");
    [second complete];
    drainMainQueue();
    [renderer drawInMTKView:(MTKView *)view];
    check(firstCompletions == 1 && secondCompletions == 1 && first.commits == 1 && second.commits == 1,
          "each submitted frame completes exactly once, even after its source disappears");
}

static void disabledSource(void) {
    TestCommands *commands = [TestCommands new];
    TestRenderer *renderer = makeRenderer(commands);
    TestView *view = [TestView new];
    __block NSUInteger completions = 0;
    [renderer invalidateRenderSource:makeSource() withCompletion:^{ completions++; }];
    [renderer disableRender];
    drainMainQueue();
    // A resize after source removal must preserve the existing completion path.
    [renderer mtkView:(MTKView *)view drawableSizeWillChange:CGSizeMake(1600, 1100)];
    [renderer drawInMTKView:(MTKView *)view];
    check(completions == 0 && commands.commits == 0,
          "source removal does not bypass the missing-drawable completion guard");
    view.hasDescriptor = view.hasDrawable = YES;
    [renderer drawInMTKView:(MTKView *)view];
    check(completions == 1 && commands.commits == 0, "a removed source releases pending completion");
    NSUInteger requests = view.drawableRequests;
    [renderer drawInMTKView:(MTKView *)view];
    check(completions == 1 && view.drawableRequests == requests && view.descriptorRequests == requests,
          "a removed source with no pending completions skips drawable acquisition");
}

int main(void) {
    @autoreleasepool {
        idleResize();
        unavailableDrawable(NO, NO);
        unavailableDrawable(NO, YES);
        unavailableDrawable(YES, NO);
        unavailableCommandBuffer();
        frameCompletions(NO);
        frameCompletions(YES);
        disabledSource();
        if (failures) return 1;
        puts("Spice renderer scheduling tests passed.");
    }
    return 0;
}
