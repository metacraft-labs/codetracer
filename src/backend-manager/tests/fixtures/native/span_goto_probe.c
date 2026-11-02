/* span_goto_probe.c -- the program mcp_goto_geid_native_test records with
 * `ct-mcr record --split` and then positions, through the MCP server's
 * `exec_script` tool and the Python API's `Trace.goto_geid`, at its span
 * markers' geids.
 *
 * Single-threaded (with argv[1] == "threads" it first starts and joins one
 * pthread, so its recording has two threads and the Linux replay refuses
 * it).  It draws SPANS random values with getrandom (a recorded input, so
 * the test cannot know them in advance), and for each span i:
 *   - declares the span's start through the recorder call (op 10), which
 *     answers the start marker's geid;
 *   - calls probe_step(i), which stores the span's value in the global
 *     g_value and returns it into the local `value`;
 *   - declares the span's end (op 11), answered with the end marker's geid,
 *     on one source line that also takes __LINE__.  A seek to the end marker
 *     stops right after that call (codetracer-specs
 *     spec/CLI/ct-mcr/debugserver.md, `qCTRestoreAt`, "A span marker"): the
 *     instruction after its `syscall` belongs to that line of this file, and
 *     `value` is a local in scope there;
 *   - prints one line with the two geids, the value and that line.
 * Every line is flushed, so each is its own recorded write(1).
 *
 * After the spans it makes TAIL raw getrandom system calls (each one a
 * recorded event; the raw call bypasses the vDSO).  `ct-mcr record --split`
 * of a recording without checkpoints cuts it into four slices by event
 * count, and the tail puts the spans, and the lock releases around the
 * first printed lines, into the first slice: the replay serves a recording
 * or its first slice from the stage0 boundary.
 *
 * Build it with -O0 -g.  The recorder call is the raw system call 0x4354
 * with the magic "ZCT-CALL" in rdi, the op in rsi and a v1 argument block
 * in rdx: the versioned wire ABI of codetracer-native-recorder's
 * ct_interpose/src/ct_interpose/trace_context_call.h (and exec_range.h for
 * the number and magic), restated here so that this fixture builds without
 * the recorder's sources.  Outside a recording the call answers -ENOSYS.
 * Adapted from codetracer-native-backend's
 * tests/programs/c/span_restore/span_restore.c (the tail is new). */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define SPANS 3
#define TAIL 1500
#define TRACE_ID "4bf92f3577b34da6a3ce929d0e0e4736"

#define RECORDER_CALL_NR 0x4354L
#define RECORDER_CALL_MAGIC 0x4c4c41432d54435aULL /* "ZCT-CALL" */

struct tc_call { /* struct ct_mcr_tc_call, version 1, 64 bytes */
    uint32_t size;
    uint32_t version;
    const char *trace_id_hex;
    const char *span_id_hex;
    const char *parent_span_id_hex;
    const char *service_name;
    uint64_t start_geid;
    int64_t wall_time_unix_ns;
    int64_t monotonic_time_ns;
};
_Static_assert(sizeof(struct tc_call) == 64, "the v1 wire layout");

/* The recorder call, expanded in the caller so that the instructions around
 * its `syscall` are attributed to the caller's line. */
#define RECORDER_CALL(out, op, arg)                                          \
    do {                                                                     \
        register long r10_ __asm__("r10") = 0;                               \
        register long r8_ __asm__("r8") = 0;                                 \
        __asm__ volatile("syscall"                                           \
                         : "=a"(out)                                         \
                         : "0"(RECORDER_CALL_NR),                            \
                           "D"((long)RECORDER_CALL_MAGIC),                   \
                           "S"((long)(op)), "d"(arg), "r"(r10_), "r"(r8_)    \
                         : "rcx", "r11", "memory");                          \
    } while (0)

volatile int g_value;
static uint32_t g_values[SPANS];

__attribute__((noinline)) int probe_step(int i) {
    /* A positive int: the debugger reads `value` as a plain integer. */
    g_value = (int)((g_values[i] ^ (uint32_t)(i + 1)) & 0x3fffffff);
    return g_value;
}

static void *worker(void *arg) {
    (void)arg;
    return NULL;
}

static void fill(struct tc_call *c, const char *span_id, uint64_t start_geid) {
    struct timespec ts;
    memset(c, 0, sizeof *c);
    c->size = 64;
    c->version = 1;
    c->trace_id_hex = TRACE_ID;
    c->span_id_hex = span_id;
    c->service_name = "span-goto";
    c->start_geid = start_geid;
    clock_gettime(CLOCK_REALTIME, &ts);
    c->wall_time_unix_ns = (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    c->monotonic_time_ns = (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "threads") == 0) {
        pthread_t t;
        if (pthread_create(&t, NULL, worker, NULL) != 0) return 3;
        pthread_join(t, NULL);
    }
    if (getrandom(g_values, sizeof g_values, 0) != (ssize_t)sizeof g_values)
        return 2;
    for (int i = 0; i < SPANS; i++) {
        char span_id[17];
        snprintf(span_id, sizeof span_id, "00f067aa0ba9%04x", (unsigned)(i + 1));
        struct tc_call c;
        long start, end;
        int end_line;
        fill(&c, span_id, 0);
        RECORDER_CALL(start, 10, &c);
        int value = probe_step(i);
        fill(&c, span_id, (uint64_t)start);
        RECORDER_CALL(end, 11, &c); end_line = __LINE__;
        printf("span %d start %ld end %ld value %d line %d\n", i, start, end,
               value, end_line);
        fflush(stdout);
    }
    unsigned char sink = 0;
    for (int k = 0; k < TAIL; k++) {
        unsigned char byte;
        if (syscall(SYS_getrandom, &byte, 1, 0) != 1) return 4;
        sink ^= byte;
    }
    printf("tail %d done %u\n", TAIL, (unsigned)sink);
    return 0;
}
