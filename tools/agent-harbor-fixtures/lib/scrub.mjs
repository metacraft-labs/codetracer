// The scrubber for Agent Harbor fixtures.
//
// A fleet snapshot is taken from a real Agent Harbor server, so before it can
// be committed it must lose three kinds of content:
//
//   1. Prompt text. A session's prompt, an agent's question to its operator
//      and the options it offers may quote anything the operator typed. They
//      are removed WHEREVER the wire format carries them, without judging
//      whether a given prompt looks harmless: the scrubber cannot know, so it
//      does not try. A removed session prompt is recorded the way the server
//      itself records a prompt it withholds from a caller -- an empty
//      `task.prompt` and `"prompt"` in the session's `withheld` list -- so the
//      fixture stays in the wire shape and a front-end shows the state it would
//      show for a withheld prompt.
//   2. Credentials, in every string (patterns in ./patterns.mjs), plus the
//      literal secrets the capture used.
//   3. Infrastructure identifiers: host names, executor ids, private addresses,
//      home directories and e-mail addresses. Hosts and executors are replaced
//      by stable aliases (`host-a`, `executor-1`) so the fleet's shape -- which
//      sessions share a host -- survives.
//
// `scrub-check.mjs` verifies the result independently of this module's
// control flow; this module only has to do the work.

import { userInfo } from "node:os";

import {
  credentialRules,
  infrastructureRules,
  scrubbedCredential,
  scrubbedOptionLabel,
} from "./patterns.mjs";

const promptBearingEventTypes = new Set(["agent_question"]);

/** The local login name, which names whoever ran the capture. */
function defaultAccountNames() {
  try {
    const name = userInfo().username;
    return name && name.length >= 4 ? [name] : [];
  } catch {
    return [];
  }
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function aliasLetters(index) {
  // a, b, …, z, aa, ab, …
  let n = index;
  let out = "";
  do {
    out = String.fromCharCode(97 + (n % 26)) + out;
    n = Math.floor(n / 26) - 1;
  } while (n >= 0);
  return out;
}

/**
 * A scrubber. `secrets` are literal strings (API keys the capture used) that
 * must never survive; `hostnames` are names to alias even where no pattern
 * would recognise them (a bare short host name such as `build-01` looks like any other word).
 */
export function createScrubber({
  secrets = [],
  hostnames = [],
  privateStrings = [],
  accountNames = defaultAccountNames(),
} = {}) {
  const hostAliases = new Map();
  const executorAliases = new Map();
  const addressAliases = new Map();
  const stats = {
    prompts: 0,
    questionTexts: 0,
    optionLabels: 0,
    credentials: 0,
    hosts: 0,
    executors: 0,
    addresses: 0,
    homeDirectories: 0,
    emails: 0,
    quotingFields: 0,
  };
  const literalSecrets = secrets.filter((s) => typeof s === "string" && s.length >= 8);
  const knownHosts = new Set(hostnames.filter((h) => h && h.length >= 3));
  // Windows of the raw prompt strings (see scrub-check.mjs, which looks for
  // the same windows): a session field that quotes any of them -- a log line
  // echoing a question, a status naming the prompt -- is replaced whole.
  const promptWindows = [];
  for (const raw of privateStrings) {
    const flat = String(raw).replace(/\s+/g, " ").trim();
    for (let i = 0; i + 32 <= flat.length || i === 0; i += 16) {
      const w = flat.slice(i, i + 32);
      if ((w.match(/[A-Za-z0-9]/g) ?? []).length >= 16) promptWindows.push(w);
      if (flat.length <= 32) break;
    }
  }

  function hostAlias(name) {
    const key = String(name).toLowerCase().replace(/\.(home\.arpa|local|lan|internal)$/, "");
    if (!hostAliases.has(key)) {
      hostAliases.set(key, `host-${aliasLetters(hostAliases.size)}`);
    }
    return hostAliases.get(key);
  }

  function executorAlias(id) {
    if (!id) return id;
    if (!executorAliases.has(id)) {
      executorAliases.set(id, `executor-${executorAliases.size + 1}`);
    }
    stats.executors += 1;
    return executorAliases.get(id);
  }

  function addressAlias(address) {
    // RFC 5737 documentation range: never routable, obviously not real.
    if (!addressAliases.has(address)) {
      addressAliases.set(address, `192.0.2.${addressAliases.size + 1}`);
    }
    return addressAliases.get(address);
  }

  function text(value) {
    if (typeof value !== "string" || value.length === 0) return value;
    let out = value;
    for (const secret of literalSecrets) {
      if (out.includes(secret)) {
        out = out.split(secret).join(scrubbedCredential);
        stats.credentials += 1;
      }
    }
    for (const rule of credentialRules) {
      out = out.replace(rule.re, () => {
        stats.credentials += 1;
        return scrubbedCredential;
      });
    }
    for (const rule of infrastructureRules) {
      out = out.replace(rule.re, (match) => {
        switch (rule.id) {
          case "lan-hostname":
            stats.hosts += 1;
            return hostAlias(match);
          case "private-ipv4":
            stats.addresses += 1;
            return addressAlias(match);
          case "home-directory":
            stats.homeDirectories += 1;
            return "~";
          case "encoded-home-directory":
            stats.homeDirectories += 1;
            return "-home-user";
          case "email":
            stats.emails += 1;
            return "[scrubbed email]";
          default:
            return match;
        }
      });
    }
    for (const account of accountNames) {
      const re = new RegExp(`(?<![A-Za-z0-9])${escapeRegExp(account)}(?![A-Za-z0-9])`, "gi");
      out = out.replace(re, () => {
        stats.homeDirectories += 1;
        return "user";
      });
    }
    for (const host of knownHosts) {
      const re = new RegExp(`(?<![A-Za-z0-9-])${escapeRegExp(host)}(?![A-Za-z0-9-])`, "gi");
      out = out.replace(re, () => {
        stats.hosts += 1;
        return hostAlias(host);
      });
    }
    return out;
  }

  /** `text`, and a field quoting a prompt is replaced whole. */
  function sessionText(value) {
    if (typeof value !== "string" || value.length < 16 || promptWindows.length === 0) return text(value);
    const flat = value.replace(/\s+/g, " ");
    if (promptWindows.some((w) => flat.includes(w))) {
      stats.quotingFields += 1;
      return "[scrubbed: quoted prompt text]";
    }
    return text(value);
  }

  function deepWith(scrubText, value) {
    if (typeof value === "string") return scrubText(value);
    if (Array.isArray(value)) return value.map((v) => deepWith(scrubText, v));
    if (value && typeof value === "object") {
      const out = {};
      for (const [key, inner] of Object.entries(value)) out[key] = deepWith(scrubText, inner);
      return out;
    }
    return value;
  }

  /** Every string of a value, with the credential and identifier rules. */
  const deep = (value) => deepWith(text, value);
  /** The same, for session data: a field quoting a prompt goes whole. */
  const deepSession = (value) => deepWith(sessionText, value);

  /** One session event (`recent_events[]`, `events/history` entries). */
  function event(raw) {
    const ev = { ...raw };
    if (promptBearingEventTypes.has(ev.type)) {
      if (typeof ev.prompt === "string" && ev.prompt.length > 0) {
        ev.prompt = "";
        stats.questionTexts += 1;
      }
      if (Array.isArray(ev.options)) {
        ev.options = ev.options.map((option, index) => {
          stats.optionLabels += 1;
          return { ...option, label: scrubbedOptionLabel(index) };
        });
      }
    }
    return deepSession(ev);
  }

  /** One `GET /api/v1/sessions` item. */
  function session(raw) {
    const item = structuredClone(raw);
    if (item.task && typeof item.task.prompt === "string" && item.task.prompt.length > 0) {
      item.task.prompt = "";
      stats.prompts += 1;
      const withheld = new Set(Array.isArray(item.withheld) ? item.withheld : []);
      withheld.add("prompt");
      item.withheld = [...withheld];
    }
    if (item.task?.labels && typeof item.task.labels === "object") {
      for (const key of Object.keys(item.task.labels)) {
        if (/executor/i.test(key)) item.task.labels[key] = executorAlias(item.task.labels[key]);
      }
    }
    if (item.workspace && typeof item.workspace.host === "string" && item.workspace.host) {
      knownHosts.add(item.workspace.host);
      item.workspace.host = hostAlias(item.workspace.host);
    }
    if (Array.isArray(item.recent_events)) item.recent_events = item.recent_events.map(event);
    const { recent_events: recent, ...rest } = item;
    const scrubbed = deepSession(rest);
    if (recent) scrubbed.recent_events = recent;
    return scrubbed;
  }

  /** `GET /api/v1/sessions/{id}/events/history`. */
  function eventHistory(raw) {
    const out = { ...raw };
    if (Array.isArray(out.events)) out.events = out.events.map(event);
    return out;
  }

  /** `GET /api/v1/sessions/{id}/info`. */
  function sessionInfo(raw) {
    const out = structuredClone(raw);
    if (out.fleet) {
      if (out.fleet.leader) out.fleet.leader = hostAlias(out.fleet.leader);
      if (Array.isArray(out.fleet.followers)) out.fleet.followers = out.fleet.followers.map(hostAlias);
    }
    if (out.executorId) out.executorId = executorAlias(out.executorId);
    return deepSession(out);
  }

  /** An SSE capture of the lifecycle feed, frame by frame. */
  function lifecycleSse(raw) {
    return raw
      .split("\n")
      .map((line) => {
        if (!line.startsWith("data:")) return text(line);
        const payload = line.slice(5).trim();
        try {
          const frame = JSON.parse(payload);
          if (frame.executor) frame.executor = executorAlias(frame.executor);
          return `data: ${JSON.stringify(deepSession(frame))}`;
        } catch {
          return `data: ${text(payload)}`;
        }
      })
      .join("\n");
  }

  return {
    text,
    deep,
    event,
    session,
    eventHistory,
    sessionInfo,
    lifecycleSse,
    hostAlias,
    executorAlias,
    stats,
    aliases: () => ({ hosts: hostAliases.size, executors: executorAliases.size }),
  };
}

/**
 * The strings a raw capture carries in prompt-bearing fields. The capture
 * keeps this list OUTSIDE the repositories so the scrub check can prove none
 * of them reached a fixture.
 */
export function promptStrings(rawSessions, rawHistories) {
  const out = new Set();
  const addEvent = (ev) => {
    if (!ev || !promptBearingEventTypes.has(ev.type)) return;
    if (typeof ev.prompt === "string") out.add(ev.prompt);
    for (const option of ev.options ?? []) if (typeof option.label === "string") out.add(option.label);
  };
  for (const item of rawSessions) {
    if (typeof item.task?.prompt === "string") out.add(item.task.prompt);
    for (const ev of item.recent_events ?? []) addEvent(ev);
  }
  for (const history of rawHistories) for (const ev of history.events ?? []) addEvent(ev);
  return [...out].filter((s) => s.trim().length >= 12);
}
