# gpui-kit dock fixtures, vendored — PLAT-20

These six files are **copied verbatim** from `longbridge/gpui-kit`:

| field | value |
| --- | --- |
| repository | <https://github.com/longbridge/gpui-kit> |
| revision | `959ccc5ea1ec23be8283c2c326467699a9b44729` |
| revision date | 2026-09-15 |
| path in that tree | `crates/base/src/dock/fixtures/` |
| license | Apache-2.0 (`LICENSE-APACHE` at that repository's root) |
| copied on | 2026-09-15 |

```text
3e6a100a3870a5b2aeac1d14eb312432515cc9ae529253bf9be13e8c48179e04  bare_tab_panel_root.json
dc90df21089188bb050b497d216999b6c92a484cc2b16d95daa4a98bcb4aed9d  layout.json
6ce77a7a4590954f2f6dc1f6dcdc820b080b63b83bc05ad1571ffc81ca2758e2  legacy_empty_tab_group.json
06c6226a4489e9311b8d6b828e4a612e732ef6f44ae7ddc57c5f5bdf101c8fa4  nested_splits.json
5aa6db83f7f7de42453841a732a7cbdba36d1243f10181b68e14ebc1d15c80c6  unregistered_panel.json
4661f3d75c390cededee7c10b06b16252bd8e85dedcfcebece16c4fc9969f3a4  zero_size_sentinel.json
```

## Why they are here, and what they are NOT

`test_gpui_dock_projection.nim` asserts that
`gpui/app/dock_projection.nim` writes gpui-kit's *persisted dock schema* —
`DockAreaState`, `PanelState`, `PanelInfo::{Stack,Tabs,Panel}`, `DockState`,
`DockPlacement` — rather than a shape somebody here invented. The honest way to
assert that is against bytes **gpui-kit itself commits and tests against**,
which is what these are: upstream's own `the_shipped_fixture_still_deserializes`
reads `layout.json` and asserts every dock and its nesting.

**They are not a mock dock, and they are not a substitute for one.** A fixture
can show that our writer produces upstream's shape and that our reader reads
upstream's documents; it cannot show that a live `DockArea` accepts what we
write, because nothing in this workspace can construct one — gpui-kit is not a
dependency here, and PLAT-20's status block records the three measured reasons.
The suite says so in its own header rather than leaving a reader to infer the
limit from what is absent.

## Keeping them honest

Two properties the suite asserts, and the second is the one that makes the first
mean anything:

1. Our **reader** descends upstream's documents structurally — it finds their
   `StackPanel` / `TabPanel` spines and their nesting depth.
2. Our reader reports **zero panes** in all six, because a leaf's identity is
   carried in `info.panel.pane` / `info.panel.contributedPane`, keys only our
   writer produces. Upstream's leaves are `StoryContainer`, `Alpha`, `Beta`,
   `Gamma` and their `info.panel` payloads are somebody else's. A reader that
   guessed a pane id out of `panel_name` would be matching vocabulary rather
   than syntax (Verification-Harness-Traps §4d), and this is the case that
   would catch it.

## If you bump the revision

Re-copy all six, update the digests above, and re-read
`crates/base/src/dock/state.rs`. Upstream's `the_serde_tags_are_frozen` test is
what makes these tags safe to bind to; if that test is gone at the new
revision, the binding has lost its guarantee and PLAT-20's status block should
say so.
