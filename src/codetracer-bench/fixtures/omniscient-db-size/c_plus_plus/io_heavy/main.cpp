// omniscient-db-size / c_plus_plus / io_heavy
//
// Profile: stresses the recorder's syscall path — writes + reads back
// a series of small files. Models a build-tool's scratch-directory
// churn.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

int main() {
    char dir_template[] = "/tmp/ct-bench-io-XXXXXX";
    if (!mkdtemp(dir_template)) {
        std::perror("mkdtemp");
        return 1;
    }
    long total = 0;
    for (int i = 0; i < 64; ++i) {
        char path[256];
        std::snprintf(path, sizeof path, "%s/chunk_%02d.bin", dir_template, i);
        char payload[8 * 65];
        int n = 8 * (i + 1);
        if (n > static_cast<int>(sizeof payload)) {
            n = sizeof payload;
        }
        for (int b = 0; b < n; ++b) {
            payload[b] = "abcdefgh"[b % 8];
        }
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) {
            return 1;
        }
        if (write(fd, payload, n) != n) {
            return 1;
        }
        close(fd);
        fd = open(path, O_RDONLY);
        if (fd < 0) {
            return 1;
        }
        char read_buf[8 * 65];
        ssize_t bytes_read = read(fd, read_buf, sizeof read_buf);
        close(fd);
        if (bytes_read < 0) {
            return 1;
        }
        total += bytes_read;
        unlink(path);
    }
    rmdir(dir_template);
    std::printf("%ld\n", total);
    return 0;
}
