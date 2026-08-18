<!--
The text after the marker below is what `ct agent prompt` prints, and only
that text: everything above it is editorial and must not end up pasted into an
agent's instructions.

Install it into a project's agent instructions with:

    ct agent prompt >> AGENTS.md

The reasoning behind each paragraph — what the prompt has to teach and why an
agent that is not told it will invent the wrong workflow — is
`codetracer-specs/DeepReview/Agent-Prompt-Guidance.md`.  That document's §3
carries a longer version of this text, including the test-certificate steps;
those are deliberately absent here, because §6 of it requires shipped guidance
to describe only commands that actually ship, and certificates do not yet.
-->
<!-- ct-agent-prompt -->

## Recording evidence for review

When you finish work that is worth a human reviewing, produce a review dataset
and hand it over. Use the ordinary commands; there is no agent-specific path.

**Run the tests, and commit once they pass.**

```sh
ct test run                   # 1. run the tests
git commit -am "…"            # 2. commit once they pass
```

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
someone else's decision), you may still collect evidence from the working tree.
Say so explicitly in your handoff, because the review then covers a state that
only exists on this machine.

**Never hand-write, edit or patch a review dataset.** A dataset is produced by
`ct review collect` from real recordings and a real diff, and that is the only
thing that makes it worth reading. A file you assembled yourself asserts
coverage and execution that never happened.
