## UUIDv7 recording-id helpers for the local trace index (M-REC-2).
##
## This module is a thin, dependency-free re-implementation of the
## ``newUuidV7`` / ``validateRecordingIdStr`` / ``parseUuidV7`` helpers
## that already live in
## ``codetracer-trace-format-nim/src/codetracer_trace_writer/uuid_v7.nim``.
## We do not import that file here because the ``codetracer`` repo
## imports the trace-format crate at the FFI/Rust boundary only —
## bringing the Nim implementation in would require a new submodule
## relationship and a wider build-system change than M-REC-2 is allowed
## to make.  The two implementations MUST agree on:
##
## - the byte layout (RFC 9562 §5.7)
## - the canonical lowercase 36-char hyphenated text form
## - validation: version nibble '7' at position 14, variant nibble in
##   {8,9,a,b} at position 19, all hex digits lowercase
##
## If you change one, change the other.  M-REC-3 may unify them.

import std/[sysrand, times]
import results

const
  UuidV7TextLen* = 36
    ## Length of the canonical hyphenated text form (8-4-4-4-12).

type
  UuidV7 = object
    bytes: array[16, byte]

const HexLower = "0123456789abcdef"

proc unixMs(): uint64 =
  ## Current Unix epoch in whole milliseconds — matches ``date +%s%3N``.
  uint64(epochTime() * 1000.0)

proc renderCanonical(u: UuidV7): string =
  ## Render the canonical lowercase hyphenated form
  ## ``xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx``.
  result = newString(UuidV7TextLen)
  var dest = 0
  for i in 0 ..< 16:
    if i == 4 or i == 6 or i == 8 or i == 10:
      result[dest] = '-'
      inc dest
    let b = u.bytes[i]
    result[dest] = HexLower[int(b shr 4)]
    inc dest
    result[dest] = HexLower[int(b and 0x0F'u8)]
    inc dest

proc newRecordingId*(): Result[string, string] =
  ## Generate a fresh UUIDv7 in canonical text form.  Returns ``err``
  ## only if the OS CSPRNG refuses to yield 10 bytes — a condition that
  ## practically never occurs on a healthy host.  See RFC 9562 §5.7.
  var randomBytes: array[10, byte]
  if not urandom(randomBytes):
    return err("uuidv7: OS CSPRNG returned no entropy")

  let ms = unixMs()
  var u = UuidV7()

  # Bytes 0..5 — 48-bit unix_ts_ms, big-endian.
  u.bytes[0] = byte((ms shr 40) and 0xFF'u64)
  u.bytes[1] = byte((ms shr 32) and 0xFF'u64)
  u.bytes[2] = byte((ms shr 24) and 0xFF'u64)
  u.bytes[3] = byte((ms shr 16) and 0xFF'u64)
  u.bytes[4] = byte((ms shr 8) and 0xFF'u64)
  u.bytes[5] = byte(ms and 0xFF'u64)

  # Bytes 6..7 — version (4 bits = 0b0111) + rand_a (12 bits).
  u.bytes[6] = byte((0x70'u8) or (randomBytes[0] and 0x0F'u8))
  u.bytes[7] = randomBytes[1]

  # Bytes 8..15 — variant (2 bits = 0b10) + rand_b (62 bits).
  u.bytes[8] = byte((randomBytes[2] and 0x3F'u8) or 0x80'u8)
  u.bytes[9] = randomBytes[3]
  for i in 0 ..< 6:
    u.bytes[10 + i] = randomBytes[4 + i]

  ok(renderCanonical(u))

proc isCanonicalUuidV7*(s: string): bool =
  ## Lightweight validator: returns true iff ``s`` matches the canonical
  ## lowercase hyphenated 36-char form of a UUIDv7 (version nibble 7,
  ## variant bits 10).  Used by tests; callers in this module accept
  ## whatever the writer produced and let downstream readers reject
  ## malformed values.
  if s.len != UuidV7TextLen:
    return false
  for hyphenPos in [8, 13, 18, 23]:
    if s[hyphenPos] != '-':
      return false
  for i, ch in s:
    if i == 8 or i == 13 or i == 18 or i == 23:
      continue
    case ch
    of '0' .. '9', 'a' .. 'f':
      discard
    else:
      return false
  if s[14] != '7':
    return false
  case s[19]
  of '8', '9', 'a', 'b':
    discard
  else:
    return false
  return true
