# M0 fixture program for trace-based incremental testing.
#
# Three functions live here. `main` calls `used_a` and `used_b`; `unused_c`
# is defined but never called. The recording (m0_three_funcs_trace.nim) has
# calls only for main/used_a/used_b, so the executed-function set is exactly
# those three and must NOT contain `unused_c`.
#
# Line numbers matter: each call in the recording enters at the definition
# line below, and the engine extracts the function body from this source by
# that line. Keep the `def` lines stable:
#   used_a  -> line 16
#   used_b  -> line 20
#   unused_c-> line 24
#   main    -> line 28

def used_a
  1 + 1
end

def used_b
  2 + 2
end

def unused_c
  3 + 3
end

def main
  used_a
  used_b
end

main
