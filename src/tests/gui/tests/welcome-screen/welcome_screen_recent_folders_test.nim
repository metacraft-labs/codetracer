## welcome_screen_recent_folders_test.nim
##
## The one suite of `welcome_screen_vm_test.nim` that is not about
## `WelcomeScreenVM` at all: `trace_index`'s recent-folder store, which is
## SQLite on disk.
##
## ## Why it is its own file
##
## It was the sole reason its parent file could not compile under `nim js`,
## and the failure was the other of the two reds on `dev`:
##
##     src/tests/gui/tests/welcome-screen/welcome_screen_vm_test.nim ... COMPILE ERROR
##       .../nim/lib/pure/osproc.nim(24, 8) Error: cannot export: quoteShell
##
## `quoteShell` does not exist on the JS target. The import chain was
## `welcome_screen_vm_test` → `src/common/trace_index` → `std/osproc`
## (`trace_index.nim:1107` spawns a process) and `db_sqlite`. Neither has a JS
## equivalent, and neither is needed by the other 44 cases in that file —
## which drive `WelcomeScreenVM` through `MockBackendService` and nothing
## else.
##
## So the fix is a split rather than a lane rejection. Rejecting the parent
## file from `vm-js` would have turned the report green while silently
## removing 44 cases from the JS backend — and BlockTracer ships the JS
## backend (Front-End-Architecture.md §6 asks for the pyramid on both). After
## the split, `welcome_screen_vm_test.nim` runs on **both** backends and only
## this one genuinely-native case is native-only.
##
## `test = true` routes every call at a temporary test database, so this suite
## touches no user state.
##
## Compile and run (C backend only — see above):
##   nim c -r --path:src/frontend/viewmodel \
##     src/tests/gui/tests/welcome-screen/welcome_screen_recent_folders_test.nim

import std/unittest

import ../../../../common/trace_index

suite "trace_index recent folders":

  test "addRecentFolder handles paths with trailing slashes/backslashes":
    # Call addRecentFolder with different trailing slash styles
    addRecentFolder("/tmp/test_dir1/", test = true)
    addRecentFolder("C:\\tmp\\test_dir2\\", test = true)
    addRecentFolder("/tmp/test_dir3", test = true)

    let folders = findRecentFolders(limit = 10, test = true)
    # Check that names are correctly extracted (not empty)
    var names: seq[string] = @[]
    for f in folders:
      if f.path == "/tmp/test_dir1" or f.path == "C:\\tmp\\test_dir2" or f.path == "/tmp/test_dir3":
        names.add(f.name)

    check "test_dir1" in names
    check "test_dir2" in names
    check "test_dir3" in names
