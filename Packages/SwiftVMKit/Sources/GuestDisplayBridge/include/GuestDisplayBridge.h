#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

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
@end

/// All entry points and callbacks run on the main thread. The library remains loaded while its
/// classes and the SPICE event loop can be alive.
id<SVMGuestDisplay> _Nullable SVMGuestDisplayLoad(NSURL *library, NSURL *socket, NSError **error);

NS_ASSUME_NONNULL_END
