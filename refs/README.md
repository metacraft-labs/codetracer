# References

Workspace-managed reference checkouts used for design study live here. They are
declared in the workspace manifests (`repos/codemirror-*.toml`) and cloned by
`repro`, so they are ignored by this repository the same way
`reprobuild/references/` is: the checkouts belong to the workspace, not to this
repo's history.

Product code must not import or link these checkouts directly.

Currently declared:

- `codemirror-state`, `codemirror-view`, `codemirror-commands`,
  `codemirror-collab` — CodeMirror 6 (MIT). The design reference for the
  headless editor ViewModel: change sets and transactions, the decoration and
  widget model, the named-command vocabulary, and collaborative editing by
  rebase against a central authority.
