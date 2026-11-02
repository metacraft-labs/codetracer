/**
 * The session secret the GUI tests give every `ct host` they start.
 *
 * `ct host` serves its page and admits its socket only to a client that
 * presents the session secret, and only from its own page's origin
 * (`src/frontend/index/host_session_guard.nim`, CLI/ct/host.md "Admission").
 * A supervisor may choose the secret and give it to `ct host` in
 * `CODETRACER_HOST_SESSION_SECRET`; these tests do exactly that, once per test
 * process, and open the page at the address the secret belongs to.
 */

import * as crypto from "node:crypto";

/** 32 random bytes, base64url: the same strength `ct host` generates. */
export const CT_HOST_SESSION_SECRET = crypto.randomBytes(32).toString("base64url");

/** Gives `env` the session secret, for a `ct host` launched with it. */
export function withCtHostSessionSecret(
  env: Record<string, string>,
): Record<string, string> {
  env.CODETRACER_HOST_SESSION_SECRET = CT_HOST_SESSION_SECRET;
  return env;
}

/** The page of a `ct host` on `port` started with `withCtHostSessionSecret`. */
export function ctHostPageUrl(port: number, host = "localhost"): string {
  return `http://${host}:${port}/?ct_session=${CT_HOST_SESSION_SECRET}`;
}
