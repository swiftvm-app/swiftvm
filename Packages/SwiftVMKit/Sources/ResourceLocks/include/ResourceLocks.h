#ifndef SWIFTVM_RESOURCE_LOCKS_H
#define SWIFTVM_RESOURCE_LOCKS_H

#define SWIFTVM_RESOURCE_FREE 0
#define SWIFTVM_RESOURCE_BUSY 1
#define SWIFTVM_RESOURCE_UNSAFE 2
#define SWIFTVM_RESOURCE_ERROR 3
#define SWIFTVM_RESOURCE_ABSENT 4

struct SwiftVMResourceProbe {
    int state;
    int errorNumber;
};

/// Inspects a regular file relative to an open package directory without disturbing the caller's locks.
struct SwiftVMResourceProbe swiftvm_probe_resource(int directory, const char *name, int required);

#endif
