import Lake
open Lake DSL

package «lean_flow_test» where
  moreLinkArgs := #["-g"]

@[default_target]
lean_exe «lean_flow_test» where
  root := `Main
  moreLeanArgs := #["-DautoImplicit=false"]
  -- Pass -g to the C compiler for DWARF debug info
  moreLeancArgs := #["-g"]
