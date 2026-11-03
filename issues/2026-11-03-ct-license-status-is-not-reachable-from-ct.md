# `ct license status` does not exist; the licence check is in ct-native-replay

| field       | value |
| ----------- | ----- |
| Status      | open |
| Recorded    | 2026-11-03 |
| Observed in | codetracer `agents` @ `9fb198c6a`, `just build-once` |
| Area        | `src/ct/codetracerconf.nim` (`StartupCommand`), `src/ct/online_sharing/check_license_command.nim`, `src/ct/launch/help_delegate.nim`; spec `Planned-Features/CodeTracer-End-User-Licensing.md` §3.3.5 |
| Requested by | operator via `@agent-upgrades` (CodeTracer-on-Agent-Harbor evaluation) |
| Related     | codetracer-native-backend `issues/2026-11-03-dev-builds-reject-production-licences-trust-the-production-key-by-default.md` |

## Observed

The operator asked whether the installed licence works and was told to run
`ct license status`. That command does not exist:

```text
$ ct license status
ct has no such subcommand
```

The only licence command `ct` has is `ct check-license`, whose help text is
"Check the current license status". It asks the sharing server about the
logged-in account (`check_license_command.nim`) and never reads the local
licence file. The licence that actually gates replay
(`~/.config/codetracer/license.dat`, or `CODETRACER_LICENSE_FILE`) is only
checked by the separate binary: `ct-native-replay license status|verify|usage`
(spec §3.3.5). A user, or an agent, who knows only `ct` cannot find out why
replays are capped at 5 per day.

## Requested change

- Add `ct license status|verify|usage` and forward them to the resolved
  `ct-native-replay license …`, the same binary replay uses, so the answer
  matches what replay will enforce. The `ct trace ...` verbs already wrap a
  recorder binary this way.
- Rename or re-describe `ct check-license` (for example "check the account's
  licence on the sharing service"), so the two are not confused.
- Document both in `docs/book/src/reference/ct_cli.md`, including
  `CODETRACER_LICENSE_FILE` and the default path.
