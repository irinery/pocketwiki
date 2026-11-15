#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/openat2.h>
#endif
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int successes = 0;
    for (int i = 0; i < 100000; i++) {
        int fd;
#if defined(__APPLE__) && defined(O_RESOLVE_BENEATH) && defined(O_NOFOLLOW_ANY) && defined(O_UNIQUE)
        fd = openat(3, argv[1], O_RDONLY | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_UNIQUE);
#elif defined(__linux__) && defined(SYS_openat2)
        struct open_how how = { .flags = O_RDONLY, .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS };
        fd = (int)syscall(SYS_openat2, 3, argv[1], &how, sizeof how);
#else
        return 77;
#endif
        if (fd < 0) continue;
        char data[128];
        ssize_t length = read(fd, data, sizeof data);
        close(fd);
        if (length > 0 && !(length == 9 && memcmp(data, "permitido", 9) == 0)) return 42;
        if (length > 0) successes++;
    }
    printf("%d\n", successes);
    return 0;
}
