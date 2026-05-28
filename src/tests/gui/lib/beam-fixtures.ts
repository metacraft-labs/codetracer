import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const repoRoot = path.resolve(__dirname, "../../../..");
export const elixirOutDir = path.join(repoRoot, "target", "beam-ui-fixtures", "elixir-canonical-flow");
export const erlangOutDir = path.join(repoRoot, "target", "beam-ui-fixtures", "erlang-canonical-flow");

const expectedMetaDatVersion = 3;
const ctfsMagic = Buffer.from([0xc0, 0xde, 0x72, 0xac, 0xe2]);
const base40Alphabet = "\0" + "0123456789abcdefghijklmnopqrstuvwxyz./-";

type PreparedBeamFixtures = {
  elixirDir: string;
  erlangDir: string;
};

type CtfsEntry = {
  name: string;
  size: bigint;
  mapBlock: bigint;
};

type CtfsReader = {
  data: Buffer;
  blockSize: number;
  entries: CtfsEntry[];
};

/**
 * Locate the codetracer-beam-recorder sibling repo. The precedence is:
 *   1. CODETRACER_BEAM_RECORDER_PATH env var (explicit override).
 *   2. Legacy CODETRACER_ELIXIR_RECORDER_PATH env var (deprecation alias).
 *   3. Sibling next to the codetracer repo (../codetracer-beam-recorder/).
 *   4. Workspace root layout used by the metacraft repo manifest.
 *
 * Failing to find the recorder is intentionally a hard error rather than a
 * skip: fixture preparation must fail loudly.
 */
function resolveRecorderRepo(): string {
  const explicit = process.env.CODETRACER_BEAM_RECORDER_PATH ?? process.env.CODETRACER_ELIXIR_RECORDER_PATH;
  if (explicit) {
    if (!fs.existsSync(path.join(explicit, "scripts", "prepare-beam-fixtures.sh"))) {
      throw new Error(
        `CODETRACER_BEAM_RECORDER_PATH does not point to a recorder repo with prepare-beam-fixtures.sh: ${explicit}`,
      );
    }
    return explicit;
  }

  const candidates = [
    path.resolve(repoRoot, "..", "codetracer-beam-recorder"),
    path.resolve(repoRoot, "..", "..", "..", "metacraft", "codetracer-beam-recorder"),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, "scripts", "prepare-beam-fixtures.sh"))) {
      return candidate;
    }
  }

  throw new Error(
    "codetracer-beam-recorder repo not found; set CODETRACER_BEAM_RECORDER_PATH",
  );
}

function base40Decode(encoded: bigint): string {
  let value = encoded;
  let decoded = "";
  while (value > 0n) {
    const index = Number(value % 40n);
    value /= 40n;
    if (index === 0) {
      break;
    }
    decoded += base40Alphabet[index];
  }
  return decoded;
}

function openCtfs(ctPath: string): CtfsReader {
  const data = fs.readFileSync(ctPath);
  if (data.length < 16) {
    throw new Error("CTFS file too short");
  }
  if (!data.subarray(0, ctfsMagic.length).equals(ctfsMagic)) {
    throw new Error("invalid CTFS magic");
  }
  const ctfsVersion = data[5];
  if (![2, 3, 4].includes(ctfsVersion)) {
    throw new Error(`unsupported CTFS version ${ctfsVersion}`);
  }

  const blockSize = data.readUInt32LE(8);
  if (![1024, 2048, 4096].includes(blockSize)) {
    throw new Error(`invalid CTFS block size ${blockSize}`);
  }

  const maxEntries = data.readUInt32LE(12);
  const entries: CtfsEntry[] = [];
  for (let offset = 16, i = 0; i < maxEntries; i++, offset += 24) {
    if (offset + 24 > data.length) {
      throw new Error("truncated CTFS entry table");
    }
    const size = data.readBigUInt64LE(offset);
    const mapBlock = data.readBigUInt64LE(offset + 8);
    const encodedName = data.readBigUInt64LE(offset + 16);
    if (size !== 0n || mapBlock !== 0n || encodedName !== 0n) {
      entries.push({
        name: base40Decode(encodedName),
        size,
        mapBlock,
      });
    }
  }

  return { data, blockSize, entries };
}

function readBlockPtr(reader: CtfsReader, blockNum: bigint, index: number): bigint {
  const offset = Number(blockNum) * reader.blockSize + index * 8;
  if (offset + 8 > reader.data.length) {
    throw new Error("CTFS block pointer outside file");
  }
  return reader.data.readBigUInt64LE(offset);
}

function levelCapacity(usable: bigint, level: number): bigint {
  let capacity = 1n;
  for (let i = 0; i < level; i++) {
    capacity *= usable;
  }
  return capacity;
}

function navigateToDataBlock(
  reader: CtfsReader,
  mappingBlock: bigint,
  level: number,
  indexWithinLevel: bigint,
  usable: bigint,
): bigint {
  if (level === 1) {
    const dataBlock = readBlockPtr(reader, mappingBlock, Number(indexWithinLevel));
    if (dataBlock === 0n) {
      throw new Error("null CTFS data block pointer");
    }
    return dataBlock;
  }

  const subCapacity = levelCapacity(usable, level - 1);
  const entryIndex = indexWithinLevel / subCapacity;
  const subIndex = indexWithinLevel % subCapacity;
  const childBlock = readBlockPtr(reader, mappingBlock, Number(entryIndex));
  if (childBlock === 0n) {
    throw new Error("null CTFS mapping block pointer");
  }
  return navigateToDataBlock(reader, childBlock, level - 1, subIndex, usable);
}

function resolveBlock(reader: CtfsReader, entry: CtfsEntry, blockIndex: bigint): bigint {
  const usable = BigInt(reader.blockSize / 8 - 1);
  let index = blockIndex;
  let currentLevelBlock = entry.mapBlock;
  let level = 1;

  while (true) {
    const capacity = levelCapacity(usable, level);
    if (index < capacity) {
      break;
    }
    index -= capacity;
    level++;
    if (level > 5) {
      throw new Error("CTFS block index exceeds mapping depth");
    }
    currentLevelBlock = readBlockPtr(reader, currentLevelBlock, Number(usable));
    if (currentLevelBlock === 0n) {
      throw new Error("null CTFS chain pointer");
    }
  }

  return navigateToDataBlock(reader, currentLevelBlock, level, index, usable);
}

function readCtfsFile(reader: CtfsReader, name: string): Buffer {
  const entry = reader.entries.find((candidate) => candidate.name === name);
  if (!entry) {
    throw new Error(`CTFS file not found: ${name}`);
  }
  if (entry.size === 0n) {
    return Buffer.alloc(0);
  }

  const chunks: Buffer[] = [];
  const numBlocks = Number((entry.size + BigInt(reader.blockSize) - 1n) / BigInt(reader.blockSize));
  let remaining = Number(entry.size);
  for (let blockIndex = 0; blockIndex < numBlocks; blockIndex++) {
    const dataBlock = resolveBlock(reader, entry, BigInt(blockIndex));
    const offset = Number(dataBlock) * reader.blockSize;
    const bytesToRead = Math.min(reader.blockSize, remaining);
    if (offset + bytesToRead > reader.data.length) {
      throw new Error("CTFS data block outside file");
    }
    chunks.push(reader.data.subarray(offset, offset + bytesToRead));
    remaining -= bytesToRead;
  }
  return Buffer.concat(chunks, Number(entry.size));
}

function hasCompatibleMetaDat(traceDir: string): boolean {
  if (!fs.existsSync(traceDir)) {
    return false;
  }

  const ctFiles = fs.readdirSync(traceDir)
    .filter((file) => file.endsWith(".ct"))
    .map((file) => path.join(traceDir, file));
  if (ctFiles.length === 0) {
    return false;
  }

  return ctFiles.some((ctFile) => {
    try {
      const metaDat = readCtfsFile(openCtfs(ctFile), "meta.dat");
      return metaDat.length >= 6 &&
        metaDat.subarray(0, 4).toString("ascii") === "CTMD" &&
        metaDat.readUInt16LE(4) === expectedMetaDatVersion;
    } catch {
      return false;
    }
  });
}

function hasCompatibleBeamFixtures(): boolean {
  return hasCompatibleMetaDat(elixirOutDir) && hasCompatibleMetaDat(erlangOutDir);
}

function fixtureForceValue(): string {
  if (process.env.FORCE === "0" && hasCompatibleBeamFixtures()) {
    return "0";
  }
  return "1";
}

/**
 * Run prepare-beam-fixtures.sh and return the resolved CTFS bundle
 * directories. Generated BEAM fixtures are deterministic and cheap compared
 * with debugging a stale bundle, so the GUI specs regenerate by default.
 * A local run may opt into reuse with FORCE=0, but only when the existing
 * CTFS bundles already contain compatible v3 meta.dat metadata.
 */
export function prepareBeamFixtures(): PreparedBeamFixtures {
  const recorderRepo = resolveRecorderRepo();
  const script = path.join(recorderRepo, "scripts", "prepare-beam-fixtures.sh");
  // The fixture generator is a bash script. On Windows a `.sh` path is not
  // directly executable, so invoke it through `bash` (present on PATH via
  // the dev shell on every platform the suite runs on).
  const result = childProcess.spawnSync("bash", [script, elixirOutDir, erlangOutDir], {
    cwd: recorderRepo,
    encoding: "utf-8",
    stdio: "pipe",
    env: {
      ...process.env,
      FORCE: fixtureForceValue(),
      TMPDIR: process.env.TMPDIR ?? path.join(repoRoot, "target", ".tmp"),
    },
    timeout: 240_000,
  });

  if (result.error || result.status !== 0) {
    throw new Error(
      `BEAM fixture preparation failed: error=${result.error}; status=${result.status}\n` +
        `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  return { elixirDir: elixirOutDir, erlangDir: erlangOutDir };
}
