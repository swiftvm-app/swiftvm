#include "ResourceLocks.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static struct SwiftVMResourceProbe error_result(void) {
    return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_ERROR, errno };
}

static struct SwiftVMResourceProbe inspect_resource(int directory, const char *name, int required) {
    int file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (file < 0) {
        if (!required && errno == ENOENT) {
            struct stat entry;
            if (fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT) {
                return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_ABSENT, 0 };
            }
            return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_UNSAFE, 0 };
        }
        return error_result();
    }
    struct stat information;
    if (fstat(file, &information) < 0) return error_result();
    if (!S_ISREG(information.st_mode) || information.st_nlink != 1 || information.st_uid != getuid()
        || (information.st_mode & 0022) != 0) {
        return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_UNSAFE, 0 };
    }
    struct flock query = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
    if (fcntl(file, F_OFD_GETLK, &query) < 0) return error_result();
    if (query.l_type != F_UNLCK) return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_BUSY, 0 };
    if (flock(file, LOCK_EX | LOCK_NB) < 0) {
        if (errno == EWOULDBLOCK) return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_BUSY, 0 };
        return error_result();
    }
    struct stat named;
    if (fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) < 0) return error_result();
    if (named.st_dev != information.st_dev || named.st_ino != information.st_ino) {
        return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_UNSAFE, 0 };
    }
    // _exit closes this process's descriptors, including its temporary flock.
    return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_FREE, 0 };
}

struct SwiftVMResourceProbe swiftvm_probe_resource(int directory, const char *name, int required) {
    if (!name || !*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) {
        return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_UNSAFE, 0 };
    }
    int channel[2];
    if (pipe(channel) < 0) return error_result();
    if (fcntl(channel[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(channel[1], F_SETFD, FD_CLOEXEC) < 0) {
        struct SwiftVMResourceProbe result = error_result();
        close(channel[0]);
        close(channel[1]);
        return result;
    }
    pid_t child = fork();
    if (child < 0) {
        struct SwiftVMResourceProbe result = error_result();
        close(channel[0]);
        close(channel[1]);
        return result;
    }
    if (child == 0) {
        // Closing ANY descriptor for an inode releases this process's POSIX record locks on it.
        // Probe in a child so opening/closing a file cannot unlock a native backend in the parent.
        // No Swift, Foundation, allocation or runtime teardown runs after fork.
        close(channel[0]);
        struct SwiftVMResourceProbe result = inspect_resource(directory, name, required);
        ssize_t sent;
        do { sent = write(channel[1], &result, sizeof(result)); } while (sent < 0 && errno == EINTR);
        _exit(sent == (ssize_t)sizeof(result) ? 0 : 1);
    }
    close(channel[1]);
    struct SwiftVMResourceProbe result = { SWIFTVM_RESOURCE_ERROR, EIO };
    size_t received = 0;
    while (received < sizeof(result)) {
        ssize_t count = read(channel[0], (char *)&result + received, sizeof(result) - received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        received += (size_t)count;
    }
    close(channel[0]);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (received != sizeof(result) || waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return (struct SwiftVMResourceProbe){ SWIFTVM_RESOURCE_ERROR, EIO };
    }
    return result;
}
