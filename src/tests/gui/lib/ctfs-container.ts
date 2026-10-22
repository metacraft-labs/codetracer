import * as fs from "node:fs";

/**
 * The CTFS container header facts the GUI tests need before they hand a
 * `.ct` file to CodeTracer.
 *
 * The container format is specified in the trace-format repository's
 * `ctfs-container.md` (§1 header, §1a version 6). The readers that enforce
 * the version are `openCtfs` in `src/ct/trace/ctfs_sources.nim` (the import
 * path `ct host` and `ct replay` take) and `check_container_version` in
 * `src/db-backend/src/ctfs_trace_reader/ctfs_container.rs`.
 */

/** The five magic bytes every CTFS container starts with (§1). */
export const ctfsMagic = Buffer.from([0xc0, 0xde, 0x72, 0xac, 0xe2]);

/**
 * The CTFS container versions this build reads (§1, §1a). Must track
 * `SupportedCtfsVersion` / `CtfsVersionV6` in `ctfs_sources.nim`.
 */
export const readableCtfsVersions: readonly number[] = [5, 6];

/**
 * The container version byte (offset 5) of the `.ct` file at `ctPath`.
 *
 * Throws when the file is too short to carry a header or does not start with
 * the CTFS magic: a caller asking for the version of something that is not a
 * container has a fixture problem, and guessing a version would hide it.
 */
export function ctfsContainerVersion(ctPath: string): number {
  const fd = fs.openSync(ctPath, "r");
  try {
    const header = Buffer.alloc(ctfsMagic.length + 1);
    const read = fs.readSync(fd, header, 0, header.length, 0);
    if (read < header.length) {
      throw new Error(`${ctPath}: too short to be a CTFS container (${read} bytes)`);
    }
    if (!header.subarray(0, ctfsMagic.length).equals(ctfsMagic)) {
      throw new Error(`${ctPath}: does not start with the CTFS magic`);
    }
    return header[ctfsMagic.length];
  } finally {
    fs.closeSync(fd);
  }
}

/**
 * The refusal the import reader prints for a container version it does not
 * read — `openCtfs`'s message, verbatim, for `version`.
 */
export function ctfsVersionRefusal(version: number): string {
  return (
    `CTFS container version ${version} is not readable: this reader reads ` +
    `versions ${readableCtfsVersions.join(" and ")}. Re-record the trace`
  );
}
