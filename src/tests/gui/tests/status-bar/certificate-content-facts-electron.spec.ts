/**
 * SB-2a — the content facts W, H and S, and the local certificate store's
 * roots, through the platform facade AS THE SHIPPED ELECTRON WINDOW RUNS IT.
 *
 * The Electron instantiation (`viewmodel/host/desktop_electron.nim`) is
 * compiled only into the renderer bundle, so no Nim test lane can execute it.
 * This spec drives it from inside the real app, through
 * `window.__ctCertificateFacts` (installed by `ui/certificate_indicator.nim`),
 * which calls the INSTALLED platform's facade and returns each outcome as
 * JSON. It asserts:
 *
 *   1. W, H and S equal git's own trees, and computing them changes no ref,
 *      not the index file (byte for byte) and not `git status`;
 *   2. a Content-Id §3 state comes back as its condition, never as an id;
 *   3. failures are VALUES: `vcs.contentId` outside a repository and
 *      `fs.listDir` on a missing directory both return failure outcomes.
 *      The second is the regression test SB-1's `jsGuard` fix never had —
 *      with the bare `except:` arm removed from `jsGuard`, node's ENOENT
 *      escapes the facade and the probe's `page.evaluate` rejects;
 *   4. the store roots follow test-certificates-spec Transport §2.1:
 *      `TEST_CERTIFICATES_DIR` wins, then `XDG_STATE_HOME`, then
 *      `~/.local/state` on Linux, and a relative value is ignored.
 *
 * No mocks: a real repository built with the system git, the real Electron
 * app on its welcome screen.
 */
import { test, expect } from "../../lib/fixtures";
import * as childProcess from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "ct-content-facts-"));
const repo = path.join(scratch, "repo");
const outside = path.join(scratch, "not-a-repository");

/** git with no user or system configuration, so a developer's
 *  `commit.gpgsign` or hooks cannot change what this fixture records. */
function git(cwd: string, ...args: string[]): string {
  return childProcess
    .execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      env: {
        ...process.env,
        GIT_CONFIG_GLOBAL: path.join(scratch, "absent-gitconfig"),
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_OPTIONAL_LOCKS: "0",
        GIT_AUTHOR_NAME: "Content Facts",
        GIT_AUTHOR_EMAIL: "content-facts@test.invalid",
        GIT_COMMITTER_NAME: "Content Facts",
        GIT_COMMITTER_EMAIL: "content-facts@test.invalid",
      },
    })
    .trim();
}

function snapshot(): string {
  const index = fs.readFileSync(path.join(repo, ".git", "index"));
  return [
    git(repo, "for-each-ref", "--format=%(refname) %(objectname)"),
    fs.readFileSync(path.join(repo, ".git", "HEAD"), "utf8"),
    crypto.createHash("sha256").update(index).digest("hex"),
    git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
  ].join("\n");
}

fs.mkdirSync(repo, { recursive: true });
fs.mkdirSync(outside, { recursive: true });
git(repo, "init", "-q", "--object-format=sha1", ".");
fs.writeFileSync(path.join(repo, "f.txt"), "base\n");
fs.writeFileSync(path.join(repo, "g.txt"), "g\n");
git(repo, "add", "-A");
git(repo, "commit", "-q", "-m", "base");

type ContentFact = {
  ok: boolean;
  kind?: string;
  id?: string;
  algorithm?: string;
  reason?: string;
  conditions?: { condition: string; paths: string[] }[];
  errorKind?: string;
  errorMessage?: string;
};

type StoreRoots = {
  ok: boolean;
  available?: boolean;
  user?: string;
  system?: string;
  problems?: string[];
};

async function probeReady(page: any): Promise<void> {
  await expect
    .poll(
      async () =>
        await page.evaluate(
          () => typeof (window as any).__ctCertificateFacts === "object",
        ),
      { timeout: 30_000 },
    )
    .toBe(true);
}

async function contentId(
  page: any,
  repository: string,
  state: "W" | "S" | "H",
  algorithm = "git-tree-sha1",
  scope: string[] = [],
): Promise<ContentFact> {
  const text = await page.evaluate(
    ([r, s, a, sc]: [string, string, string, string[]]) =>
      (window as any).__ctCertificateFacts.contentId(r, s, a, sc),
    [repository, state, algorithm, scope],
  );
  return JSON.parse(text);
}

async function storeRoots(
  page: any,
  env: Record<string, string | null>,
): Promise<StoreRoots> {
  const text = await page.evaluate((vars: Record<string, string | null>) => {
    for (const [key, value] of Object.entries(vars)) {
      if (value === null) delete (process as any).env[key];
      else (process as any).env[key] = value;
    }
    return (window as any).__ctCertificateFacts.storeRoots();
  }, env);
  return JSON.parse(text);
}

test.describe("SB-2a: certificate content facts through the Electron facade", () => {
  test.use({ launchMode: "welcome" });

  test.afterAll(() => {
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  test("W, H and S are git's own trees, and the call moves nothing", async ({
    ctPage,
  }) => {
    await probeReady(ctPage);
    const head = "git-tree-sha1:" + git(repo, "rev-parse", "HEAD^{tree}");

    // A committed, clean tree: all three are HEAD's tree.
    for (const state of ["W", "S", "H"] as const) {
      const fact = await contentId(ctPage, repo, state);
      expect(fact.ok, JSON.stringify(fact)).toBe(true);
      expect(fact.kind).toBe("vcikComputed");
      expect(fact.id).toBe(head);
    }

    // A partially staged file: S is `write-tree` of the index, W what
    // `git commit -a` would record, and neither is H.
    fs.writeFileSync(path.join(repo, "f.txt"), "staged\n");
    git(repo, "add", "f.txt");
    fs.writeFileSync(path.join(repo, "f.txt"), "staged\nedited\n");
    fs.writeFileSync(path.join(repo, "untracked.txt"), "u\n");
    const before = snapshot();

    const w = await contentId(ctPage, repo, "W");
    const s = await contentId(ctPage, repo, "S");
    const h = await contentId(ctPage, repo, "H");
    expect(snapshot()).toBe(before);

    fs.copyFileSync(path.join(repo, ".git", "index"), path.join(scratch, "index-copy"));
    const expectedS = childProcess
      .execFileSync("git", ["write-tree"], {
        cwd: repo,
        encoding: "utf8",
        env: { ...process.env, GIT_INDEX_FILE: path.join(scratch, "index-copy") },
      })
      .trim();
    expect(s.id).toBe("git-tree-sha1:" + expectedS);
    expect(h.id).toBe(head);
    const clone = path.join(scratch, "w-clone");
    git(scratch, "clone", "-q", repo, clone);
    fs.copyFileSync(path.join(repo, "f.txt"), path.join(clone, "f.txt"));
    git(clone, "commit", "-q", "-a", "-m", "as tested");
    expect(w.id).toBe("git-tree-sha1:" + git(clone, "rev-parse", "HEAD^{tree}"));
    expect(w.id).not.toBe(s.id);
    expect(s.id).not.toBe(h.id);
  });

  test("a state with no content id is its condition, never an id", async ({
    ctPage,
  }) => {
    await probeReady(ctPage);
    git(repo, "update-index", "--assume-unchanged", "g.txt");
    try {
      const w = await contentId(ctPage, repo, "W");
      expect(w.ok, JSON.stringify(w)).toBe(true);
      expect(w.kind).toBe("vcikNoContentId");
      expect(w.id).toBe("");
      expect(w.conditions).toEqual([
        { condition: "ncAssumeUnchanged", paths: ["g.txt"] },
      ]);
      // H is computable here, and W must not have borrowed it.
      const h = await contentId(ctPage, repo, "H");
      expect(h.kind).toBe("vcikComputed");
    } finally {
      git(repo, "update-index", "--no-assume-unchanged", "g.txt");
    }
    const other = await contentId(ctPage, repo, "H", "git-tree-sha256");
    expect(other.ok).toBe(true);
    expect(other.kind).toBe("vcikCannotCompute");
    expect(other.id).toBe("");
  });

  test("the Electron facade returns failures as values", async ({ ctPage }) => {
    await probeReady(ctPage);
    // Outside a repository: an error VALUE, not an id and not a throw.
    const fact = await contentId(ctPage, outside, "W");
    expect(fact.ok).toBe(false);
    expect(fact.errorKind).toBe("pkFailed");
    expect(fact.errorMessage).toContain("not inside a git working tree");

    // A missing directory: `pkNotFound`, which only reaches here if
    // `jsGuard` caught node's ENOENT. Without its bare `except:` arm the
    // exception escapes the facade and this `evaluate` rejects.
    const listing = JSON.parse(
      await ctPage.evaluate(
        (p: string) => (window as any).__ctCertificateFacts.listDir(p),
        path.join(scratch, "no-such-directory"),
      ),
    );
    expect(listing.ok).toBe(false);
    expect(listing.errorKind).toBe("pkNotFound");

    // And a directory that IS there lists, so the failure above is the
    // missing path's and not the probe's.
    const present = JSON.parse(
      await ctPage.evaluate(
        (p: string) => (window as any).__ctCertificateFacts.listDir(p),
        repo,
      ),
    );
    expect(present.ok).toBe(true);
    expect(present.names).toContain("f.txt");
  });

  test("the host resolves the local certificate store's roots", async ({
    ctPage,
  }) => {
    await probeReady(ctPage);
    // ct-home-sweep: not codetracer state -- HOME / XDG_STATE_HOME are
    // redirected to exercise the cross-tool test-certificates store's own §2.1
    // rules, which CODETRACER_HOME deliberately does not override.
    const explicit = path.join(scratch, "explicit-store");
    const state = path.join(scratch, "state");
    const home = path.join(scratch, "home");

    const wins = await storeRoots(ctPage, {
      TEST_CERTIFICATES_DIR: explicit,
      XDG_STATE_HOME: state,
    });
    expect(wins.ok).toBe(true);
    expect(wins.available).toBe(true);
    expect(wins.user).toBe(explicit);

    if (process.platform === "linux") {
      const xdg = await storeRoots(ctPage, {
        TEST_CERTIFICATES_DIR: null,
        XDG_STATE_HOME: state,
      });
      expect(xdg.user).toBe(path.join(state, "test-certificates"));

      const fallback = await storeRoots(ctPage, {
        TEST_CERTIFICATES_DIR: null,
        XDG_STATE_HOME: null,
        HOME: home,
      });
      expect(fallback.user).toBe(path.join(home, ".local", "state", "test-certificates"));

      const relative = await storeRoots(ctPage, {
        TEST_CERTIFICATES_DIR: "relative/store",
        XDG_STATE_HOME: "relative-state",
        HOME: home,
      });
      expect(relative.user).toBe(path.join(home, ".local", "state", "test-certificates"));
      const ignored = (relative.problems ?? []).filter((p) => p.includes("ignored"));
      expect(ignored.length).toBe(2);

      const uid = String(process.getuid!());
      const system = await storeRoots(ctPage, { TEST_CERTIFICATES_SYSTEM_DIR: null });
      expect(system.system).toBe(`/var/lib/test-certificates/${uid}`);
      const systemExplicit = await storeRoots(ctPage, {
        TEST_CERTIFICATES_SYSTEM_DIR: path.join(scratch, "system"),
      });
      expect(systemExplicit.system).toBe(path.join(scratch, "system", uid));
    }

    // The resolved root is read through the existing fs facade.
    fs.mkdirSync(path.join(explicit, "git-tree-sha1"), { recursive: true });
    fs.writeFileSync(path.join(explicit, "git-tree-sha1", "record.toml"), "x = 1\n");
    const roots = await storeRoots(ctPage, { TEST_CERTIFICATES_DIR: explicit });
    const listing = JSON.parse(
      await ctPage.evaluate(
        (p: string) => (window as any).__ctCertificateFacts.listDir(p),
        path.join(roots.user!, "git-tree-sha1"),
      ),
    );
    expect(listing.ok).toBe(true);
    expect(listing.names).toEqual(["record.toml"]);
  });
});
