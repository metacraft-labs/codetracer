/**
 * Collapse collected renderer errors into DISTINCT faults.
 *
 * Why this exists: a count cannot distinguish one cause from many. A single
 * throw on a reactive write re-fires on every subsequent write, so a run that
 * reports "1257 JS errors" is reporting one defect 1257 times -- and a
 * harness that prints the first 50 entries prints the same line 50 times,
 * while the second *distinct* fault, the one that would name the real cause,
 * scrolls past unseen.
 *
 * Kept in its own module (rather than inside `fixtures.ts`) so it can be
 * exercised without launching Electron; see
 * `tests/harness/error-grouping.spec.ts`.
 */

/** One distinct renderer fault, plus how many times it repeated. */
export interface ErrorGroup {
  /** The full first occurrence, message and stack. */
  first: string;
  /** How many collected entries share this signature. */
  count: number;
  /** Index of the first occurrence in the collected order. */
  firstIndex: number;
}

/**
 * Reduce one collected entry to the signature that identifies its *cause*.
 *
 * Volatile parts are stripped: Nim's JS backend appends a per-throw
 * `| details: {...}` blob, mangles every generic instantiation with a
 * `__<hash>_u<id>` suffix, and stack frames carry absolute paths with
 * line:column. None of those distinguish two defects; all of them make two
 * reports of one defect look distinct.
 */
function signatureOf(entry: string): string {
  const lines = entry.split("\n");
  const head = (lines[0] ?? "")
    .replace(/ \| details: .*$/, "")
    .replace(/__[A-Za-z0-9]+_u\d+/g, "")
    .replace(/\(?(?:file|https?):\/\/\S+?\)?(?=\s|$)/g, "<url>")
    .replace(/:\d+:\d+/g, ":<pos>");
  // The topmost stack frame separates two different callers of one runtime
  // helper -- e.g. `nimCopy` reached from two unrelated reactive writes.
  const frame = (lines.find((l) => l.trim().startsWith("at ")) ?? "")
    .replace(/__[A-Za-z0-9]+_u\d+/g, "")
    .replace(/:\d+:\d+/g, ":<pos>")
    .trim();
  return `${head} ${frame}`;
}

/**
 * Group `errors` by cause, preserving first-occurrence order.
 *
 * `groups[0]` is therefore the EARLIEST fault -- which, for a cascade, is the
 * one that caused the rest.
 */
export function groupErrorsBySignature(errors: readonly string[]): ErrorGroup[] {
  const byKey = new Map<string, ErrorGroup>();
  for (const [index, entry] of errors.entries()) {
    const key = signatureOf(entry);
    const existing = byKey.get(key);
    if (existing === undefined) {
      byKey.set(key, { first: entry, count: 1, firstIndex: index });
    } else {
      existing.count += 1;
    }
  }
  return Array.from(byKey.values()).sort((a, b) => a.firstIndex - b.firstIndex);
}

/**
 * Render the grouped report the failure path prints.
 *
 * Returns one string per line so the caller decides where it goes, and so the
 * self-test can assert on the exact text an operator reads.
 */
export function formatErrorGroups(
  errors: readonly string[],
  maxGroups = 10,
): string[] {
  if (errors.length === 0) return [];
  const groups = groupErrorsBySignature(errors);
  const out: string[] = [
    `  FAIL JS errors: ${errors.length} total, ${groups.length} distinct`,
  ];
  for (const [i, group] of groups.slice(0, maxGroups).entries()) {
    out.push(
      `  FAIL JS error [${i + 1}/${groups.length}] x${group.count}, ` +
        `first at index ${group.firstIndex}:`,
    );
    for (const line of group.first.split("\n")) {
      out.push(`    ${line}`);
    }
  }
  if (groups.length > maxGroups) {
    out.push(`    ... and ${groups.length - maxGroups} more distinct errors`);
  }
  return out;
}
