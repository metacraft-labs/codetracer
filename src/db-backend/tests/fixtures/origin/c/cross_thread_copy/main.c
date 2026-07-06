/* cross_thread_copy — C
 *
 * Multi-threaded fixture: the writer thread writes a literal into the
 * shared `g_shared` slot; the main (querying) thread later reads it
 * into `local`. The M11 algorithm must:
 *
 *   1. Detect that the last write to `local`'s address came from a
 *      different thread than the querying one.
 *   2. Tag the hop with kind=CrossThreadCopy and confidence=0.6.
 *   3. Switch the replay session to the writing thread before reading
 *      the source line for the next hop.
 *
 * Expected chain for `local` queried at the printf line:
 *
 *   hop 0: target=local       rhs=g_shared   OriginKind=TrivialCopy        source_variable=g_shared (confidence>=0.9)
 *   hop 1: target=g_shared    rhs=99         OriginKind=CrossThreadCopy    source_variable=99       (confidence=0.6)
 *   hop 2: terminator=Literal(int, value=99)
 *
 * The exact shape depends on how the optimiser / DWARF line tables
 * place the assignment; the test asserts only that AT LEAST ONE hop
 * carries kind=CrossThreadCopy and confidence~0.6.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>

static atomic_int g_shared = 0;
__attribute__((noinline)) static void rr_watchpoint_boundary(void);

static void *writer(void *arg) {
    (void)arg;
    atomic_store(&g_shared, 99);
    return NULL;
}

int main(void) {
    pthread_t tid;
    pthread_create(&tid, NULL, writer, NULL);
    pthread_join(tid, NULL);
    volatile int local = 0;
    local = atomic_load(&g_shared);
    rr_watchpoint_boundary();
    printf("%d\n", local);
    return 0;
}

__attribute__((noinline)) static void rr_watchpoint_boundary(void) {
    /*
     * RR value-origin tests need an observable replay event after the local
     * stack write and before the later read at printf. sched_yield gives rr a
     * clean syscall/scheduler boundary without reading or mutating `local`.
     */
    extern int sched_yield(void);
    sched_yield();
}
