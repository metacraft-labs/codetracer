/* Product RR omniscient DB acceptance fixture.
 *
 * This is intentionally ordinary C: no inline assembly, no backend-specific
 * labels, and no handcrafted instruction windows. The test records this
 * program through `ct record --backend rr` and validates the product-produced
 * omniscient artifacts.
 */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile uint64_t g_counter = 5;
static volatile uint64_t g_slots[4] = {0, 0, 0, 0};

__attribute__((noinline)) static void update_counter(uint64_t delta) {
    uint64_t before = g_counter;
    g_counter = before + delta; /* MODEL:counter */
}

__attribute__((noinline)) static void heap_phase(void) {
    volatile uint64_t* heap = (volatile uint64_t*)calloc(4, sizeof(uint64_t));
    if (heap == NULL) {
        _exit(3);
    }
    heap[0] = 0x1111;             /* MODEL:heap0 */
    heap[1] = 0x2222;             /* MODEL:heap1 */
    heap[2] = 0x3333;             /* MODEL:heap2 */
    g_slots[0] = heap[0] + heap[1]; /* MODEL:slot0 */
    g_slots[1] = heap[2] ^ 0x55;  /* MODEL:slot1 */
    free((void*)heap);
}

__attribute__((noinline)) static void stack_phase(uint64_t seed) {
    volatile uint64_t local[4] = {0, 0, 0, 0};
    local[0] = seed + 7;          /* MODEL:local0 */
    local[1] = local[0] * 3;      /* MODEL:local1 */
    local[2] = local[1] ^ 0x44;   /* MODEL:local2 */
    local[3] = local[2] + g_counter; /* MODEL:local3 */
    g_slots[2] = local[3];        /* MODEL:slot2 */
}

__attribute__((noinline)) static int os_phase(void) {
    char path[] = "/tmp/ct-rr-product-omniscient-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        return -1;
    }
    const char payload[] = "rr-product-omniscient\n";
    if (write(fd, payload, sizeof(payload) - 1) != (ssize_t)(sizeof(payload) - 1)) {
        close(fd);
        unlink(path);
        return -1;
    }
    if (lseek(fd, 0, SEEK_SET) < 0) {
        close(fd);
        unlink(path);
        return -1;
    }
    char buf[sizeof(payload)] = {0};
    ssize_t got = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    unlink(path);
    if (got <= 0) {
        return -1;
    }
    return (int)buf[0];
}

int main(void) {
    write(STDOUT_FILENO, "BEGIN\n", 6);
    int first = os_phase();
    if (first < 0) {
        return 2;
    }

    update_counter(12); /* g_counter: 5 -> 17 */
    heap_phase();       /* heap: 0 -> 0x1111, 0 -> 0x2222, 0 -> 0x3333 */
    update_counter(17); /* g_counter: 17 -> 34 */
    stack_phase((uint64_t)first);
    update_counter(17); /* g_counter: 34 -> 51 */

    write(STDOUT_FILENO, "END\n", 4);
    printf("%llu %llu %llu %llu\n",
           (unsigned long long)g_counter,
           (unsigned long long)g_slots[0],
           (unsigned long long)g_slots[1],
           (unsigned long long)g_slots[2]);
    return g_counter == 51 ? 0 : 1;
}
