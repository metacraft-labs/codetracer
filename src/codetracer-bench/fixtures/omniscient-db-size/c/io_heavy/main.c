/* omniscient-db-size / c / io_heavy */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    char dir_template[] = "/tmp/ct-bench-io-XXXXXX";
    if (!mkdtemp(dir_template)) {
        perror("mkdtemp");
        return 1;
    }
    long total = 0;
    for (int i = 0; i < 64; ++i) {
        char path[256];
        snprintf(path, sizeof path, "%s/chunk_%02d.bin", dir_template, i);
        char payload[8 * 65];
        int n = 8 * (i + 1);
        if (n > (int)sizeof payload) n = sizeof payload;
        for (int b = 0; b < n; ++b) payload[b] = "abcdefgh"[b % 8];
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) return 1;
        if (write(fd, payload, n) != n) return 1;
        close(fd);
        fd = open(path, O_RDONLY);
        if (fd < 0) return 1;
        char buf[8 * 65];
        ssize_t r = read(fd, buf, sizeof buf);
        close(fd);
        if (r < 0) return 1;
        total += r;
        unlink(path);
    }
    rmdir(dir_template);
    printf("%ld\n", total);
    return 0;
}
