/* Read beneath a trusted directory FD; 10=escape, 11=unavailable, 12=invalid. */
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
int main(int argc, char **argv) {
    if (argc != 2 || !argv[1][0] || argv[1][0] == '/') return 10;
    char *path = strdup(argv[1]);
    if (!path) return 11;
    int dir = dup(3);
    if (dir < 0) { free(path); return 11; }
    char *part = path;
    for (;;) {
        char *slash = strchr(part, '/');
        if (slash) *slash = '\0';
        if (!*part || !strcmp(part, ".") || !strcmp(part, "..")) { close(dir); free(path); return 10; }
        int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC;
        if (slash) flags |= O_DIRECTORY;
        int fd = openat(dir, part, flags);
        if (fd < 0) {
            int err = errno;
            close(dir); free(path);
            return (err == ELOOP || err == ENOTDIR) ? 10 : 11;
        }
        close(dir); dir = fd;
        if (!slash) break;
        part = slash + 1;
    }
    struct stat st;
    if (fstat(dir, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > 4 * 1024 * 1024) { close(dir); free(path); return 12; }
    char buffer[16384]; size_t total = 0;
    for (;;) {
        ssize_t n = read(dir, buffer, sizeof buffer);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { close(dir); free(path); return 11; }
        if (!n) break;
        total += (size_t)n;
        if (total > 4 * 1024 * 1024) { close(dir); free(path); return 12; }
        ssize_t pos = 0;
        while (pos < n) {
            ssize_t written = write(STDOUT_FILENO, buffer + pos, (size_t)(n - pos));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { close(dir); free(path); return 11; }
            pos += written;
        }
    }
    close(dir); free(path); return 0;
}
