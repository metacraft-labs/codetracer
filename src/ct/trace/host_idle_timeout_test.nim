import
  std/unittest,
  ./host

suite "ct host idle timeout parsing":
  test "default is 10 minutes when empty":
    let parsed = parseIdleTimeoutMs("")
    check parsed.ok
    check parsed.value == 10 * 60 * 1000

  test "parses units and disables with zero":
    check parseIdleTimeoutMs("5s").value == 5 * 1_000
    check parseIdleTimeoutMs("2m").value == 2 * 60 * 1_000
    check parseIdleTimeoutMs("1h").value == 1 * 60 * 60 * 1_000
    check parseIdleTimeoutMs("0").value == -1
    check parseIdleTimeoutMs("never").value == -1
    check parseIdleTimeoutMs("off").value == -1

  test "rejects invalid inputs":
    check not parseIdleTimeoutMs("abc").ok
