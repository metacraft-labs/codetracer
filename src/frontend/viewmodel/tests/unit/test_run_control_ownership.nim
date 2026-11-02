import std/unittest
import ../../viewmodels/run_control_ownership

suite "a refused click preserves another editor's accepted run":
  test "remove only the newly armed editor":
    var spinning = @["accepted editor", "declined editor"]
    rollbackRunSpinner(spinning, "declined editor", false)
    check spinning == @["accepted editor"]
  test "an already running editor keeps its membership":
    var spinning = @["accepted editor"]
    rollbackRunSpinner(spinning, "accepted editor", true)
    check spinning == @["accepted editor"]
  test "a synchronous settle has already removed the click":
    var spinning = @["accepted editor"]
    rollbackRunSpinner(spinning, "declined editor", false)
    check spinning == @["accepted editor"]
