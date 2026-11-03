// What the Agent Harbor fixture scrubber removes and what the scrub check
// refuses to find. One table serves both, so the check can never be looser
// than the scrubber it verifies (or the other way round).
//
// Each rule has a stable `id` (reported by the check, asserted by its
// self-test) and a regular expression with the `g` flag. Matches are never
// printed in full: the check reports a rule id, a file, a line and a redacted
// preview.

/** Credentials: tokens and keys in the formats their issuers document. */
export const credentialRules = [
  // Agent Harbor REST credentials (`Authorization: ApiKey <key>` / `Bearer`).
  { id: "authorization-apikey", re: /\bApiKey\s+[A-Za-z0-9._~+\/=-]{12,}/g },
  { id: "authorization-bearer", re: /\bBearer\s+[A-Za-z0-9._~+\/=-]{16,}/g },
  // JSON Web Tokens: three base64url segments, the first a JSON header
  // (https://www.rfc-editor.org/rfc/rfc7519#section-3).
  { id: "jwt", re: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g },
  // GitHub tokens (https://github.blog/engineering/platform-security/behind-githubs-new-authentication-token-formats/).
  { id: "github-token", re: /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})/g },
  // OpenAI / Anthropic style secret keys.
  { id: "llm-api-key", re: /\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}/g },
  // AWS access key ids (https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_identifiers.html).
  { id: "aws-access-key", re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g },
  // Slack tokens.
  { id: "slack-token", re: /\bxox[abprs]-[A-Za-z0-9-]{10,}/g },
  // Google API keys.
  { id: "google-api-key", re: /\bAIza[0-9A-Za-z_-]{35}\b/g },
  // PEM private keys (https://www.rfc-editor.org/rfc/rfc7468).
  { id: "private-key", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g },
  // `api_key = "…"`, `"apiKey": "…"`, `password: …` and the like, with a
  // value long enough to be a secret rather than a field name in prose.
  {
    id: "assigned-secret",
    re: /\b(?:api[_-]?key|apikey|secret|password|passwd|token|auth[_-]?token|access[_-]?token)["']?\s*[:=]\s*["']?(?!\[scrubbed)[A-Za-z0-9._~+\/=-]{16,}/gi,
  },
  // URLs carrying credentials in their userinfo (https://www.rfc-editor.org/rfc/rfc3986#section-3.2.1).
  { id: "url-credentials", re: /\b[a-z][a-z0-9+.-]*:\/\/[^\s\/:@"']+:[^\s\/@"']+@/gi },
];

/** Infrastructure the fleet's addresses and accounts would reveal. */
export const infrastructureRules = [
  // Home-LAN and overlay names and addresses.
  { id: "lan-hostname", re: /\b[a-z0-9-]+\.(?:home\.arpa|local|lan|internal)\b/gi },
  {
    id: "private-ipv4",
    re: /\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01])|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.\d{1,3}\b/g,
  },
  // Absolute home directories name the account that captured them.
  { id: "home-directory", re: /(?:\/home\/|\/Users\/|C:\\\\Users\\\\)[A-Za-z0-9._-]+/g },
  // The same directory as tools encode it into a single path component
  // (`/tmp/claude-1000/-home-<user>-<project>/`).
  { id: "encoded-home-directory", re: /-(?:home|Users)-(?!user-)[A-Za-z0-9._]+(?=-)/g },
  // E-mail addresses.
  { id: "email", re: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g },
];

/** Every rule the check applies to every fixture file. */
export const allRules = [...credentialRules, ...infrastructureRules];

/** The text a scrubbed credential is replaced with. */
export const scrubbedCredential = "[scrubbed credential]";

/** Placeholder labels for an agent question's options. */
export function scrubbedOptionLabel(index) {
  return `Option ${index + 1}`;
}

/** A short, non-reversible preview of a match for a report. */
export function redact(match) {
  const text = String(match);
  if (text.length <= 6) return "*".repeat(text.length);
  return `${text.slice(0, 3)}…(${text.length} chars)`;
}
