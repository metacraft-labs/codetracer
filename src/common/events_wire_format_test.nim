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
