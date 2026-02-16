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
