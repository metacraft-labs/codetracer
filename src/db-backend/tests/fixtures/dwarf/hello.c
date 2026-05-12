/* M-DWARF-1 test fixture for the `dwarf_index` module.
 *
 * A deliberately tiny C program that, when compiled with `-g`, produces a
 * small ELF with enough DWARF line/function info for unit tests to assert:
 *   * `from_elf_bytes()` parses the ELF without error.
 *   * `resolve_pc(pc)` returns a `(file = "hello.c", line, function)`
 *     triple for any PC inside `add` or `main`.
 *   * `source_files()` enumerates "hello.c" (and possibly compiler-injected
 *     internal files — the test asserts containment, not exact equality).
 *
 * Build (from this directory):
 *     gcc -O0 -g -no-pie -nostdlib -static \
 *         -Wl,-e,_start -o hello.elf hello.c hello_start.S
 *
 * `_start` is provided by `hello_start.S` so we don't pull in libc; that
 * keeps the fixture small and avoids non-determinism from glibc versions.
 *
 * The fixture is checked into the repo (`hello.elf`) so tests don't need
 * a C toolchain at `cargo test` time. Regenerate via the `rebuild.sh`
 * script in this directory if the source ever changes.
 */

int add(int a, int b) {
    int sum = a + b;
    return sum;
}

int compute(int x) {
    int doubled = add(x, x);
    return doubled;
}

int main(void) {
    int result = compute(21);
    return result;
}
