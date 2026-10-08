// The browser leg of `ci/test/identity-live-device-grant.sh`: a real person,
// simulated no further than a real Chromium can be, approving the device
// authorization the probe is at that moment blocked polling for.
//
// WHY A BROWSER AND NOT AN API CALL
// =================================
// The probe (`identity_live_device_grant_probe.nim`) performs RFC 8628's
// device flow, which is split across two agents ON PURPOSE: the device asks
// for a code, and a SECOND agent — a human at a browser, on a machine with a
// keyboard — approves it. Approving it by posting to the issuer's session API
// would close the loop through a door the product's users do not have, and the
// resulting "the round trip works" would be a claim about the harness. So this
// file drives the page a person is actually shown, types into the form they
// actually type into, and presses the button they actually press. Every hop is
// a real navigation over TLS the browser genuinely verified.
//
// This is modelled directly on isonim-platform's
// `local-dev/tests/login_browser.mjs` — same Chromium, same
// `ignoreHTTPSErrors: false`, same `input[name="loginName"]` → password →
// second-factor-"Skip" sequence, same navigation trail printed on the way out.
// What it adds is the leg that file has no reason to have: the device
// authorization's own consent page.
//
// WHAT ZITADEL'S LOGIN-V1 DEVICE PAGES ACTUALLY LOOK LIKE (measured against
// the local stack on 2026-09-30; none of this is in Zitadel's docs):
//
//   * `/device?user_code=XXXX-YYYY` — the `verification_uri_complete` — does
//     NOT render a "enter your code" page. It consumes the code server-side
//     and 302s straight to `/ui/login/login?authRequestID=<n>`, the ordinary
//     hosted login form. A harness that waited for a code field would hang.
//   * That form is the same one `login_browser.mjs` drives:
//     `input[name="loginName"]`, submit, then `input[type="password"]`.
//   * The second-factor SETUP prompt (a "Skip" button) may or may not appear —
//     the instance default policy offers it after a first successful password
//     check and remembers a skip. It is handled conditionally, never waited
//     for.
//   * The consent page is titled "Device Authorization" and lands on the URL
//     `/ui/login/device/%7Baction%7D?authRequestID=<n>` — with a LITERAL
//     `{action}` path segment, percent-encoded by the browser. That is
//     Zitadel rendering its template's placeholder into the form's own URL; it
//     is not a 404 and not a bug in this harness. Do not match on the path.
//   * Its form has NO `action` attribute. It carries two submit buttons that
//     each supply one, `formaction="./allowed"` and `formaction="./denied"`,
//     resolved relative to `/ui/login/device/`. So the buttons are selected by
//     their formaction, which is the only thing about them that is stable —
//     their labels ("Allow" / "Deny") are localised.
//
// Environment (all supplied by identity-live-device-grant.sh):
//   CT_PLAYWRIGHT      module specifier for playwright
//   CT_CHROMIUM        path to the Chromium binary
//   CT_RESOLVER_RULES  --host-resolver-rules value; the dev hosts are not in
//                      /etc/hosts and this is the browser's way to say so
//   CT_APPROVE_URL     the probe's `verification_uri_complete`
//   CT_LOGIN_USER, CT_LOGIN_PASSWORD
//   CT_PROFILE         optional: a HOME whose .pki/nssdb trusts the dev CA
//   CT_CA_SPKI         optional: base64 sha256 of the dev CA's SPKI, pinned
//                      with --ignore-certificate-errors-spki-list when no NSS
//                      database could be built. Either way the browser checks
//                      the chain; neither is `--ignore-certificate-errors`.
//   CT_DEVICE_ACTION   allow (default) | deny | none — `deny` and `none` exist
//                      for the harness's negative controls, and a control that
//                      cannot be expressed is a control nobody runs.

const playwrightModule = await import(process.env.CT_PLAYWRIGHT || 'playwright');
const chromium = playwrightModule.chromium ?? playwrightModule.default?.chromium;
if (!chromium) throw new Error('playwright resolved but exposes no chromium export');

const env = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing environment variable ${k}`);
  return v;
};

const APPROVE_URL = env('CT_APPROVE_URL');
const USER = env('CT_LOGIN_USER');
const PASSWORD = env('CT_LOGIN_PASSWORD');
const ACTION = process.env.CT_DEVICE_ACTION || 'allow';
if (!['allow', 'deny', 'none'].includes(ACTION)) {
  throw new Error(`CT_DEVICE_ACTION must be allow|deny|none, got ${ACTION}`);
}

let pass = 0, fail = 0;
const trail = [];
const ok = (m) => { console.log(`  \x1b[32mPASS\x1b[0m ${m}`); pass++; };
const no = (m) => { console.log(`  \x1b[31mFAIL\x1b[0m ${m}`); fail++; };
const check = (cond, m) => cond ? ok(m) : no(m);
const info = (m) => console.log(`       ${m}`);
const section = (m) => console.log(`\n\x1b[1m${m}\x1b[0m`);

const args = [`--host-resolver-rules=${env('CT_RESOLVER_RULES')}`];
if (process.env.CT_CA_SPKI) {
  // A PIN, not a bypass. Chromium still builds and checks the chain; this says
  // "additionally accept the chain whose CA has exactly this public key", and
  // the key is the dev CA's. `--ignore-certificate-errors` would accept
  // anything, and is deliberately not used.
  args.push(`--ignore-certificate-errors-spki-list=${process.env.CT_CA_SPKI}`);
}

const browser = await chromium.launch({
  executablePath: env('CT_CHROMIUM'),
  headless: true,
  args,
  // When CT_PROFILE is set it is a throwaway HOME whose NSS database trusts
  // the dev CA — the same arrangement login_browser.mjs uses, and the
  // preferred one, because then nothing about verification is special-cased.
  env: process.env.CT_PROFILE
    ? { ...process.env, HOME: process.env.CT_PROFILE }
    : { ...process.env },
});

// ONE context: the login and the consent step share a session cookie the
// issuer sets, exactly as they do for a person.
const ctx = await browser.newContext({ ignoreHTTPSErrors: false });
const page = await ctx.newPage();
page.on('framenavigated', (f) => { if (f === page.mainFrame()) trail.push(f.url()); });

try {
  // ------------------------------------------------------------------
  section('D1. verification_uri_complete lands on the issuer\'s hosted login');
  // ------------------------------------------------------------------
  await page.goto(APPROVE_URL, { waitUntil: 'load' });

  const landed = new URL(page.url());
  // The regression this guards: if the `/device` handler ever stops consuming
  // `?user_code=`, this lands on a code-entry page instead and every selector
  // below misses. Naming the path here makes that a failure with a sentence
  // rather than a timeout.
  check(/\/ui\/login\//.test(landed.pathname),
    `the device endpoint handed the browser to the hosted login (${landed.pathname})`);
  const body0 = await page.evaluate(() => document.body.innerText);
  check(!/"code"\s*:\s*5/.test(body0) && !/Not Found/i.test(body0),
    'it is a page, not a 404 body');

  const loginField = page.locator('input[name="loginName"]');
  check(await loginField.count() > 0,
    'the issuer rendered its login form (an input named loginName)');

  // ------------------------------------------------------------------
  section('D2. The credential is typed into the ISSUER\'s own form');
  // ------------------------------------------------------------------
  // CodeTracer never sees this password. The device flow exists so that it
  // cannot: the CLI holds a device code, the browser holds the credential, and
  // the two meet only at the issuer.
  await loginField.fill(USER);
  await Promise.all([page.waitForLoadState('load'), loginField.press('Enter')]);
  const pwField = page.locator('input[type="password"]');
  await pwField.waitFor({ state: 'visible', timeout: 15000 });
  ok('the issuer accepted the login name and asked for a password');

  await pwField.fill(PASSWORD);
  await Promise.all([page.waitForLoadState('load'), pwField.press('Enter')]);

  // The second-factor SETUP prompt, clicked through as a person would rather
  // than policy-edited away — a login flow with a step removed is a different
  // login flow. Conditional because the issuer remembers a skip: it appeared
  // on the first run against this stack and not on the second.
  const skip = page.locator('button[name="skip"], button:has-text("Skip")');
  if (await skip.count() > 0) {
    info(`the issuer offered second-factor setup ("${await page.title()}"); skipping, as a user may`);
    await Promise.all([page.waitForLoadState('load'), skip.first().click()]);
  }

  // ------------------------------------------------------------------
  section('D3. The device-authorization consent page');
  // ------------------------------------------------------------------
  const allow = page.locator('button[formaction="./allowed"]');
  const deny = page.locator('button[formaction="./denied"]');
  await allow.waitFor({ state: 'visible', timeout: 20000 });

  const consentText = await page.evaluate(() => document.body.innerText);
  check(await deny.count() > 0,
    'the consent page offers BOTH an allow and a deny — a page with only one button is not consent');
  // The page names the user and the scopes. Asserted because it is the whole
  // content of the decision being asked for: a consent screen that does not
  // say what is being consented to is a rubber stamp.
  check(consentText.includes(USER),
    `the consent page names the user who typed the password (${USER})`);
  check(/openid/.test(consentText),
    'the consent page names the scopes being granted');
  info(`consent reads: ${consentText.split('\n').filter((l) => l.trim()).slice(1, 2).join(' ').slice(0, 160)}`);

  // ------------------------------------------------------------------
  section(`D4. The decision: ${ACTION}`);
  // ------------------------------------------------------------------
  if (ACTION === 'none') {
    // The harness's "approve nothing" control. The browser walked the whole
    // flow and stopped at the button — which is exactly the state a user who
    // wandered off leaves the device in, and the probe must keep polling
    // `authorization_pending` and then time out rather than succeed.
    info('leaving the authorization un-decided, on purpose');
  } else if (ACTION === 'deny') {
    await Promise.all([page.waitForLoadState('load'), deny.first().click()]);
    ok(`the browser pressed Deny (now at ${new URL(page.url()).pathname})`);
  } else {
    await Promise.all([page.waitForLoadState('load'), allow.first().click()]);
    const after = await page.evaluate(() => document.body.innerText);
    // Zitadel's post-approval page is a plain "you can close this" screen.
    // Asserting that the consent form is GONE is the load-bearing part: a
    // click that re-rendered the same form would mean nothing was granted.
    check(await page.locator('button[formaction="./allowed"]').count() === 0,
      'the consent form is gone — the decision was recorded');
    info(`the issuer now says: ${after.split('\n').filter((l) => l.trim()).slice(0, 2).join(' ').slice(0, 160)}`);
  }

} catch (e) {
  no(`the browser leg threw: ${e.message.split('\n')[0]}`);
} finally {
  console.log('\n\x1b[1mNavigation trail\x1b[0m');
  for (const u of trail) console.log(`  ${u.length > 150 ? u.slice(0, 150) + '…' : u}`);
  await browser.close();
}

console.log(`\n\x1b[1m${pass} passed, ${fail} failed\x1b[0m`);
process.exit(fail === 0 ? 0 : 1);
