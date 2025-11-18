import
  std/unittest,
  ../index/idle_timeout

suite "idle timeout helpers":
  test "check interval clamps and disables":
    check idleCheckInterval(-1) == -1
    check idleCheckInterval(500) == MinCheckIntervalMs
    check idleCheckInterval(2_000) == 1_000
    check idleCheckInterval(20_000) == MaxCheckIntervalMs

  test "no connection exits after timeout":
    check not shouldExitIdle(false, 0, 0, 999, 1_000)
    check shouldExitIdle(false, 0, 0, 1_001, 1_000)

  test "active connection uses activity timer":
    check not shouldExitIdle(true, 0, 900, 1_000, 200)
    check shouldExitIdle(true, 0, 0, 1_000, 900)

  test "disabled timeout never exits":
    check not shouldExitIdle(false, 0, 0, 10_000, -1)
    check not shouldExitIdle(true, 0, 0, 10_000, -1)
