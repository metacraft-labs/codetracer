## M-REC-5 wire-format flip tests for `UpdateTableArgs` / `TableUpdate`.
##
## Pins the Nim-side JSON wire format that the Nim frontend sends to the
## Rust db-backend (and vice-versa) for the `ct/update-table` /
## `ct/updated-table` IPC pair.  After M-REC-4 (db-backend Rust types)
## the canonical JSON keys for the in-memory event-slot index are
## `eventSlot`; the bare key `traceId` is reserved for OpenTelemetry W3C
## TraceContext.
##
## These tests fail at compile time if `traceId` survives anywhere on
## `UpdateTableArgs` or `TableUpdate`, and at runtime if the serialized
## JSON emits the legacy key.  They mirror the Rust-side serde tests
## ~update_table_args_serializes_event_slot_as_camel_case~ and
## ~table_update_serializes_event_slot_as_camel_case~ in
## ~src/db-backend/src/task.rs~.
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/events_wire_format_test \
##       src/common/events_wire_format_test.nim

import std / [unittest, json]

type
  langstring = string

include common_types / codetracer_features / events

suite "M-REC-5 — events.nim wire format":

  test "UpdateTableArgs serializes `eventSlot` (camelCase) and drops `traceId`":
    let args = UpdateTableArgs(
      isTrace: true,
      eventSlot: 7,
    )
    let j = %args
    # The field renamed from `traceId` to `eventSlot` (parent spec
    # §2's third meaning of trace_id removed; only OTel W3C
    # TraceContext keeps the bare `trace_id` name).
    check j.hasKey("eventSlot")
    check j["eventSlot"].getInt == 7
    check not j.hasKey("traceId")
    check not j.hasKey("trace_id")

  test "TableUpdate serializes `eventSlot` (camelCase) and drops `traceId`":
    let update = TableUpdate(
      isTrace: false,
      eventSlot: 0,
    )
    let j = %update
    check j.hasKey("eventSlot")
    check j["eventSlot"].getInt == 0
    check not j.hasKey("traceId")
    check not j.hasKey("trace_id")

  test "UpdateTableArgs round-trips eventSlot through JSON":
    let args = UpdateTableArgs(
      isTrace: true,
      eventSlot: 42,
    )
    let serialized = $(%args)
    let parsed = parseJson(serialized).to(UpdateTableArgs)
    check parsed.eventSlot == 42
    check parsed.isTrace == true

  test "TableUpdate round-trips eventSlot through JSON":
    let update = TableUpdate(
      isTrace: true,
      eventSlot: 3,
    )
    let serialized = $(%update)
    let parsed = parseJson(serialized).to(TableUpdate)
    check parsed.eventSlot == 3
    check parsed.isTrace == true

suite "EventLogKind — the kinds of trace-events.md, by ordinal":

  # `trace-events.md` §"EventLogKind (u8 enum)", spelled out rather than
  # derived from the enum: the db-backend sends a kind as its ordinal, and
  # `selectedKinds` crosses back indexed by it, so a reordering here would
  # relabel every event the frontend shows.
  const SpecKinds = [
    (0, "Write"), (1, "WriteFile"), (2, "WriteOther"), (3, "Read"),
    (4, "ReadFile"), (5, "ReadOther"), (6, "ReadDir"), (7, "OpenDir"),
    (8, "CloseDir"), (9, "Socket"), (10, "Open"), (11, "Error"),
    (12, "TraceLogEvent"), (13, "EvmEvent"), (14, "WriteStderr"),
    (15, "Exec"), (16, "ReadEnv"), (17, "WriteEnv"), (18, "Stat"),
    (19, "CreateDir"), (20, "RemoveDir"), (21, "RemoveFile"),
    (22, "Rename"), (23, "ChangeDir"),
  ]

  test "every kind has its spec ordinal, and there are no others":
    check EventLogKind.high.ord + 1 == SpecKinds.len
    for (ordinal, name) in SpecKinds:
      check $EventLogKind(ordinal) == name

  test "the kind filter carries one flag per kind":
    var args = UpdateTableArgs()
    args.selectedKinds[EventLogKind.ChangeDir] = true
    let flags = (%args)["selectedKinds"]
    check flags.len == SpecKinds.len
    for i in 0 ..< flags.len:
      check flags[i].getBool == (i == EventLogKind.ChangeDir.ord)
