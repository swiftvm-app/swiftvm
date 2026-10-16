#import "GuestDisplayBridge.h"
#include <dlfcn.h>

id<SVMGuestDisplay> SVMGuestDisplayLoad(NSURL *library, NSURL *socket, NSError **error) {
    void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    id<SVMGuestDisplay> (*create)(NSURL *) = handle ? dlsym(handle, "SVMCreateSpiceDisplay") : NULL;
    if (!create) {
        const char *detail = dlerror();
        if (error) {
            *error = [NSError errorWithDomain:@"SwiftVM.GuestDisplay" code:1 userInfo:@{
                NSLocalizedDescriptionKey: detail ? @(detail) : @"The display library that comes with QEMU is incomplete."
            }];
        }
        if (handle) dlclose(handle);
        return nil;
    }
    id<SVMGuestDisplay> display = create(socket);
    if (!display && error) {
        *error = [NSError errorWithDomain:@"SwiftVM.GuestDisplay" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"Metal couldn't create the machine's display."
        }];
    }
    return display;
}
