/* Read using a single kernel-enforced beneath lookup on trusted dir FD 3.
 * Exit 10: escape; 11: unsupported/unavailable; 12: invalid size/type. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if defined(__linux__)
#include <sys/syscall.h>
#if defined(__has_include)
#if __has_include(<linux/openat2.h>)
#include <linux/openat2.h>
#define HAVE_LINUX_OPENAT2 1
#endif
#endif
#endif

static int beneath(int dir, const char *path) {
#if defined(__APPLE__) && defined(O_RESOLVE_BENEATH) && defined(O_NOFOLLOW_ANY) && defined(O_UNIQUE)
    return openat(dir, path, O_RDONLY | O_CLOEXEC | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_UNIQUE);
#elif defined(__linux__) && defined(SYS_openat2) && defined(HAVE_LINUX_OPENAT2)
    struct open_how how = { .flags = O_RDONLY | O_CLOEXEC, .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS };
    return (int)syscall(SYS_openat2, dir, path, &how, sizeof how);
#else
    (void)dir; (void)path; errno = ENOTSUP; return -1;
#endif
}
static int probe(void) {
    char dir[] = "/tmp/pocketwiki-beneath.XXXXXX";
    if (!mkdtemp(dir)) return 11;
    int root = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root < 0) { rmdir(dir); return 11; }
    int ok = 0, sub = -1, f = -1, test = -1, outside = -1;
    char outside_path[sizeof dir + 16] = {0};
    char escape_path[sizeof dir + 16];
    if (snprintf(outside_path, sizeof outside_path, "%s.outside", dir) >= (int)sizeof outside_path) goto done;
    const char *base = strrchr(outside_path, '/');
    if (!base || snprintf(escape_path, sizeof escape_path, "..%s", base) >= (int)sizeof escape_path) goto done;
    outside = open(outside_path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (outside < 0) goto done;
    close(outside); outside = -1;
    if (mkdirat(root, "sub", 0700)) goto done;
    sub = openat(root, "sub", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (sub < 0) goto done;
    f = openat(sub, "ok", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (f < 0) goto done;
    close(f); f = -1;
    if (symlinkat("sub", root, "link")) goto done;
    test = beneath(root, "sub/ok");
    if (test < 0) goto done;
    close(test); test = -1;
    test = beneath(root, "link/ok");
    if (test >= 0) goto done;
    test = beneath(root, escape_path);
    if (test >= 0) goto done;
#if defined(__APPLE__)
    if (linkat(sub, "ok", root, "hard", 0)) goto done;
    test = beneath(root, "hard");
    if (test >= 0) goto done;
#endif
    ok = 1;
done:
    if (test >= 0) close(test);
    if (f >= 0) close(f);
    if (outside >= 0) close(outside);
    if (outside_path[0]) unlink(outside_path);
    unlinkat(root, "hard", 0);
    if (sub >= 0) { unlinkat(sub, "ok", 0); close(sub); }
    unlinkat(root, "link", 0);
    unlinkat(root, "sub", AT_REMOVEDIR);
    close(root); rmdir(dir);
    return ok ? 0 : 11;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--probe")) return probe();
    if (argc != 2 || !argv[1][0] || argv[1][0] == '/') return 10;
    int fd = beneath(3, argv[1]);
    if (fd < 0) {
        int err = errno;
#if defined(ENOTCAPABLE)
        if (err == ENOTCAPABLE) return 10;
#endif
        if (err == ELOOP || err == EXDEV || err == EAGAIN || err == ENOTDIR) return 10;
        return 11;
    }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 0 || st.st_size > 4 * 1024 * 1024) { close(fd); return 12; }
    char buffer[16384]; size_t total = 0;
    for (;;) {
        ssize_t n = read(fd, buffer, sizeof buffer);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { close(fd); return 11; }
        if (!n) break;
        total += (size_t)n;
        if (total > 4 * 1024 * 1024) { close(fd); return 12; }
        ssize_t pos = 0;
        while (pos < n) {
            ssize_t written = write(STDOUT_FILENO, buffer + pos, (size_t)(n - pos));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { close(fd); return 11; }
            pos += written;
        }
    }
    close(fd); return 0;
}
