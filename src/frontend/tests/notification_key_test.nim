## notification_key_test.nim
##
## What the status bar takes as one notification (`notification_key.nim`):
## words that differ only in a `0x` address are one notice, and any other
## difference keeps two notices apart. The status bar's own use of the key is
## held by `later_session_launch_failure_test.nim`.

import std/unittest
import ../notification_key

suite "notification key":
  test "sentences differing only in an address have one key":
    check notificationKey("rr stopped at 0x7ffd5a1c2b40 in main") ==
      notificationKey("rr stopped at 0x7FFD5A1C2F88 in main")
    check notificationKey("rr stopped at 0x7ffd5a1c2b40") == "rr stopped at 0x…"

  test "every address in a sentence is replaced":
    check notificationKey("from 0x10 to 0xdeadbeef.") == "from 0x… to 0x…."

  test "different words keep different keys":
    check notificationKey("rr stopped at 0x10") != notificationKey("rr crashed at 0x10")
    check notificationKey("worker 1 failed") != notificationKey("worker 2 failed")

  test "a 0x that is not an address is left alone":
    check notificationKey("a0x1f") == "a0x1f"
    check notificationKey("0x") == "0x"
    check notificationKey("0xg") == "0xg"
    check notificationKey("") == ""
