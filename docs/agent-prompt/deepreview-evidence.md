<!--
The text after the marker below is what `ct agent prompt` prints, and only
that text: everything above it is editorial and must not end up pasted into an
agent's instructions.

Install it into a project's agent instructions with:

    ct agent prompt >> AGENTS.md

The reasoning behind each paragraph — what the prompt has to teach and why an
agent that is not told it will invent the wrong workflow — is
`codetracer-specs/DeepReview/Agent-Prompt-Guidance.md`.  That document's §3
is the source of this text, test-certificate paragraphs included: `ct test run`
issues a certificate bound to the content of the tracked files, so the
workflow is test, then commit, with no second run after the commit.  The test
command is spelled here exactly as it is invoked (`ct test run --workspace .`),
with the standalone `ct-test` fallback, because the `ct` binary refuses
`test run` (it is built with refc; see `src/ct_test/ct_test.nim`).
-->
<!-- ct-agent-prompt -->

## Recording evidence for review

When you finish work that is worth a human reviewing, produce a review dataset
and hand it over. Use the ordinary commands; there is no agent-specific path.

**Run the tests, then commit exactly what you tested.**

```sh
git add <any new files>       # 1. new files must be tracked before testing
ct test run --workspace .     # 2. run the tests — a pass issues the certificate
git commit -am "…"            # 3. commit once they pass
```

If `ct` answers that it cannot run the tests itself, run step 2 with the
standalone runner instead: `ct-test test run --workspace .`. If that is not
installed either, say so in your handoff; do not skip the tests.

The certificate from step 2 is valid for your working tree as it stands, and
covers the commit in step 3 **as long as that commit records exactly what was
tested**. Do not run `ct test` again after committing; there is nothing for it
to add. Do not commit only part of what you tested, add files after testing,
or let a hook reformat files at commit time — each produces a commit the tests
never saw. If you have to change anything after the tests pass, run `ct test`
again before committing.

**Then collect the review dataset and hand it over:**

```sh
ct review collect --diff main..HEAD --recordings .ct/runs -o review.json
ct agent evidence review.json
```

`ct agent evidence` reads the session, task and workspace from your
environment; you do not need to pass them. If it tells you it cannot work out
which session you are in, say so — do not invent a `--session` value, because
an id that does not match the session you are actually running in attaches the
review to the wrong conversation.

`ct review collect` needs recordings to collect from: record the runs you want
reviewed (`ct record …`) into the directory you pass to `--recordings`. If it
reports that it found none, that is the thing to fix — a dataset collected
from nothing is not evidence.

**If the tests fail, stop and fix them.** Do not collect evidence for a failing
run in the hope the reviewer will sort it out — say what failed instead.

**If you genuinely cannot commit** (the work is incomplete, or committing is
someone else's decision), collect evidence from the working tree. The
certificate is valid for it, and will cover the commit whoever makes it, if
that commit records the same content. Say in your handoff that the work is
uncommitted, because until it is committed it exists only on this machine.

**Never** attempt to produce, edit or sign a certificate yourself. Certificates
are issued only as a side effect of actually running the tests, and any tool
that appears to offer a shortcut is not one.

**Never hand-write, edit or patch a review dataset.** A dataset is produced by
`ct review collect` from real recordings and a real diff, and that is the only
thing that makes it worth reading. A file you assembled yourself asserts
coverage and execution that never happened.
