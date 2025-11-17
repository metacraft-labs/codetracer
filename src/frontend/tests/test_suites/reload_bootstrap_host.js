// Headless smoke test for `ct host` bootstrap replay across reloads.
// Spawns `server_index.js` in server mode, connects a socket, disconnects,
// then reconnects to confirm cached bootstrap events are replayed for each
// startup mode we care about (welcome/no-trace/shell-ui).

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const Module = require("node:module");

function resolveBuildDir() {
  const candidates = [
    process.env.NIX_CODETRACER_EXE_DIR,
    path.resolve(__dirname, ".."),
    path.resolve(__dirname, "..", "..", "..", "build-debug"),
    path.resolve(__dirname, "..", ".."),
  ].filter(Boolean);

  for (const candidate of candidates) {
    const serverIndex = path.join(candidate, "server_index.js");
    if (fs.existsSync(serverIndex)) return candidate;
  }
  throw new Error("Cannot locate build directory with server_index.js");
}

const buildDir = resolveBuildDir();
const repoRoot = path.resolve(buildDir, "..", "..");
process.env.NODE_PATH = path.join(repoRoot, "node_modules");
Module._initPaths();

const io = require("socket.io-client");

const nodeBin = path.join(buildDir, "bin", "node");
const serverIndex = path.join(buildDir, "server_index.js");
const testHome = path.join(buildDir, "tests", "reload-bootstrap-home");
const editFixture = path.join(
  repoRoot,
  "test-programs",
  "nim_sudoku_solver",
  "main.nim",
);

function log(label, message) {
  process.stderr.write(`[${label}] ${message}\n`);
}

function ensureDirClean(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function collectBootstrap(client, expectedEvents, label) {
  return await new Promise((resolve, reject) => {
    const order = [];
    const payloads = new Map();
    const pending = new Set(expectedEvents);
    let sentAck = false;

    const cleanup = (err) => {
      clearTimeout(timer);
      client.off("connect_error");
      client.off("error");
      for (const id of expectedEvents) client.off(id);
      if (err) reject(err);
    };

    const timer = setTimeout(() => {
      const missing = Array.from(pending);
      cleanup(new Error(`[${label}] Timed out waiting for: ${missing.join(", ")}`));
    }, 12_000);

    client.onAny((event, ...args) => {
      log(label, `received ${event}`);
      if (args.length > 0 && typeof args[0] === "string" && args[0].length > 120) {
        return;
      }
    });
    client.on("connect_error", (err) => cleanup(err));
    client.on("error", (err) => cleanup(new Error(`[${label}] socket error: ${err}`)));

    for (const id of expectedEvents) {
      client.on(id, (payload) => {
        if (payloads.has(id)) return;
        if (id === "CODETRACER::started" && !sentAck) {
          sentAck = true;
          client.emit("CODETRACER::started", {});
        }
        order.push(id);
        payloads.set(id, payload);
        pending.delete(id);
        if (pending.size === 0) {
          cleanup();
          resolve({ order, payloads });
        }
      });
    }
  });
}

async function bootstrapRound(port, label, expectedOrder, attempts = 4) {
  for (let i = 1; i <= attempts; i += 1) {
    const client = io(`http://127.0.0.1:${port}`, {
      transports: ["websocket"],
      forceNew: true,
      reconnection: false,
      timeout: 3_000,
    });
    try {
      const result = await collectBootstrap(client, expectedOrder, `${label}-attempt-${i}`);
      client.disconnect();
      return result;
    } catch (err) {
      client.disconnect();
      if (i === attempts) throw err;
      await delay(200);
    }
  }
  throw new Error(`[${label}] retry loop exhausted unexpectedly`);
}

async function stopProcess(proc, label) {
  return await new Promise((resolve) => {
    let settled = false;
    const killGroup = (signal) => {
      try {
        process.kill(-proc.pid, signal);
      } catch (err) {
        if (err && err.code !== "ESRCH") log(label, `kill group failed: ${err}`);
      }
      try {
        proc.kill(signal);
      } catch (err) {
        if (err && err.code !== "ESRCH") log(label, `kill proc failed: ${err}`);
      }
    };

    const finish = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    proc.once("exit", finish);
    killGroup("SIGTERM");
    setTimeout(() => {
      if (!settled) {
        log(label, "forcing shutdown after timeout");
        killGroup("SIGKILL");
      }
    }, 5_000);
  });
}

async function runScenario(label, scenarioArgs, expectedOrder, portBase) {
  const httpPort = portBase;
  const socketPort = portBase + 1;

  const env = {
    ...process.env,
    HOME: testHome,
    XDG_CONFIG_HOME: path.join(testHome, ".config"),
    NIX_CODETRACER_EXE_DIR: buildDir,
    LINKS_PATH_DIR: buildDir,
    CODETRACER_TEST: "1",
  };
  fs.mkdirSync(env.XDG_CONFIG_HOME, { recursive: true });

  const args = [
    serverIndex,
    "--port",
    `${httpPort}`,
    "--frontend-socket-port",
    `${socketPort}`,
    "--backend-socket-port",
    `${socketPort}`,
    ...scenarioArgs,
  ];

  const server = spawn(nodeBin, args, {
    cwd: repoRoot,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });

  server.stdout.on("data", (data) => log(label, data.toString().trim()));
  server.stderr.on("data", (data) => log(label, data.toString().trim()));

  try {
    const first = await bootstrapRound(socketPort, `${label}-first`, expectedOrder);
    const second = await bootstrapRound(socketPort, `${label}-second`, expectedOrder);

    assert.deepStrictEqual(
      second.order,
      expectedOrder,
      `[${label}] replay order mismatch`,
    );

    for (const id of expectedOrder) {
      assert.ok(
        first.payloads.has(id),
        `[${label}] first connection missing payload for ${id}`,
      );
      assert.ok(second.payloads.has(id), `[${label}] replay missing payload for ${id}`);
      assert.deepStrictEqual(
        second.payloads.get(id),
        first.payloads.get(id),
        `[${label}] payload for ${id} changed across reconnect`,
      );
    }

    log(label, `bootstrap replayed successfully on port ${socketPort}`);
  } finally {
    await stopProcess(server, label);
  }
}

async function main() {
  ensureDirClean(testHome);

  if (!fs.existsSync(editFixture)) {
    throw new Error(`Edit fixture not found: ${editFixture}`);
  }

  const scenarios = [
    {
      label: "welcome-screen replay",
      args: ["--welcome-screen"],
      expected: ["CODETRACER::started", "CODETRACER::welcome-screen"],
    },
    {
      label: "edit replay",
      args: ["edit", editFixture],
      expected: ["CODETRACER::started", "CODETRACER::no-trace"],
    },
    {
      label: "shell-ui replay",
      args: ["--shell-ui"],
      expected: ["CODETRACER::started", "CODETRACER::start-shell-ui"],
    },
  ];

  let portBase = 5_600;
  for (const scenario of scenarios) {
    await runScenario(scenario.label, scenario.args, scenario.expected, portBase);
    portBase += 10;
  }

  log("reload-bootstrap-host", "all scenarios passed");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
