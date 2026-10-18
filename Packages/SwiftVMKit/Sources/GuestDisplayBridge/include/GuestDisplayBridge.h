#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A view of part of the display, drawn on its own: one window of a guest's app on the Mac.
@protocol SVMGuestDisplayRegion <NSObject>
@property (nonatomic, readonly) NSView *view;
/// The part of the display shown, in its pixels from the top left corner. An empty one is all of it.
@property (nonatomic) CGRect region;
/// Stops drawing. The view shows nothing after that.
- (void)close;
@end

/// The display library is packaged with QEMU. Keeping this boundary independent of SPICE lets a
/// build without QEMU still run Apple's virtualization engine and the command-line tools.
@protocol SVMGuestDisplay <NSObject>
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, copy, nullable) void (^connected)(NSError * _Nullable error);
@property (nonatomic, copy, nullable) void (^disconnected)(NSString *reason);
@property (nonatomic, copy, nullable) void (^resized)(CGSize size);
- (void)connect;
- (void)close;
- (void)key:(uint16_t)scancode down:(BOOL)down;
/// Buttons use RFB's wire order: left, middle, right, up, down, left wheel, right wheel.
- (void)pointerAt:(CGPoint)point buttons:(uint8_t)buttons;
- (void)requestSize:(CGSize)size NS_SWIFT_NAME(requestSize(_:));
- (void)screenshot:(void (^)(NSData * _Nullable png))completion;
@optional
/// A new view of part of the display. A library built before there were any doesn't answer.
- (nullable id<SVMGuestDisplayRegion>)makeRegion;
@end

/// All entry points and callbacks run on the main thread. The library remains loaded while its
/// classes and the SPICE event loop can be alive.
id<SVMGuestDisplay> _Nullable SVMGuestDisplayLoad(NSURL *library, NSURL *socket, NSError **error);

NS_ASSUME_NONNULL_END
