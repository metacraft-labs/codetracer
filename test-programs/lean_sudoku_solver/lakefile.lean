import Lake
open Lake DSL

-- Build with debug info for codetracer RR-based tracing.
-- `lake build` produces an executable in `.lake/build/bin/`.
package «lean_sudoku_solver» where
  moreLinkArgs := #["-g"]

@[default_target]
lean_exe «sudoku» where
  root := `Main
  moreLeanArgs := #["-DautoImplicit=false"]
  -- Pass -g to the C compiler so DWARF debug info is present in the binary
  moreLeancArgs := #["-g"]
