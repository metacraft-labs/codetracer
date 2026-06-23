# M0 fixture program for trace-based incremental testing.
#
# Three functions live here. `main` calls `used_a` and `used_b`; `unused_c`
# is defined but never called. The recorded trace (see ../trace) therefore
# has Call records only for main/used_a/used_b, so `readExecutedFunctions`
# must return exactly those three and must NOT return `unused_c`.
#
# Line numbers matter: the fixture trace's Function records carry the
# definition lines below, and later milestones extract the function body from
# this source by line. Keep the `def` lines stable:
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
