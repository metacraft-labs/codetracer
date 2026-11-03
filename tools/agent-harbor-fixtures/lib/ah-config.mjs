// Reads the Agent Harbor servers the local `ah` CLI is configured with, so
// the capture talks to the same fleet server `ah` does, with the same
// credential, and the scrub check knows which literal key and which host name
// must never appear in a fixture.
//
// `ah` keeps them in `$XDG_CONFIG_HOME/agent-harbor/config.toml` (default
// `~/.config/agent-harbor/config.toml`) as `[servers.<name>]` tables with
// `url`, `enabled` and either `api_key` or `api_key_file`. This reader
// understands exactly those keys -- a TOML subset of `[table]` headers and
// `key = "string" | true | false` lines (https://toml.io/en/v1.0.0) -- and
// ignores everything else, which is enough for a file `ah` itself writes.
//
// AH_FIXTURE_SERVER_URL and AH_FIXTURE_API_KEY_FILE override the
// configuration, for a capture from a different server.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function expandHome(path) {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return join(homedir(), path.slice(2));
  return path;
}

function parseValue(raw) {
  const value = raw.trim().replace(/\s+#.*$/, "");
  if (value === "true") return true;
  if (value === "false") return false;
  const quoted = /^"((?:[^"\\]|\\.)*)"$/.exec(value) ?? /^'([^']*)'$/.exec(value);
  return quoted ? quoted[1] : value;
}

export function ahConfigPath() {
  const base = process.env.XDG_CONFIG_HOME || join(homedir(), ".config");
  return join(base, "agent-harbor", "config.toml");
}

/** `[{ name, url, enabled, apiKey }]`; the key is read from its file. */
export function readAhServers() {
  if (process.env.AH_FIXTURE_SERVER_URL) {
    const keyFile = process.env.AH_FIXTURE_API_KEY_FILE;
    return [
      {
        name: "override",
        url: process.env.AH_FIXTURE_SERVER_URL,
        enabled: true,
        apiKey: keyFile && existsSync(expandHome(keyFile))
          ? readFileSync(expandHome(keyFile), "utf8").trim()
          : null,
      },
    ];
  }
  const path = ahConfigPath();
  if (!existsSync(path)) return [];
  const servers = new Map();
  let current = null;
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.startsWith("#") || trimmed.length === 0) continue;
    const header = /^\[([^\]]+)\]$/.exec(trimmed);
    if (header) {
      const parts = header[1].split(".");
      current = parts[0] === "servers" && parts.length === 2 ? parts[1] : null;
      if (current && !servers.has(current)) servers.set(current, { name: current });
      continue;
    }
    if (!current) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    servers.get(current)[trimmed.slice(0, eq).trim()] = parseValue(trimmed.slice(eq + 1));
  }
  return [...servers.values()].map((s) => {
    let apiKey = typeof s.api_key === "string" ? s.api_key : null;
    if (!apiKey && typeof s.api_key_file === "string") {
      const file = expandHome(s.api_key_file);
      if (existsSync(file)) apiKey = readFileSync(file, "utf8").trim();
    }
    return { name: s.name, url: s.url, enabled: s.enabled !== false, apiKey };
  });
}

/** The server a capture reads: the first enabled one with a URL. */
export function captureServer() {
  const server = readAhServers().find((s) => s.enabled && s.url);
  if (!server) {
    throw new Error(
      `no enabled Agent Harbor server in ${ahConfigPath()}; set AH_FIXTURE_SERVER_URL ` +
        "(and AH_FIXTURE_API_KEY_FILE) to capture from one",
    );
  }
  return server;
}
