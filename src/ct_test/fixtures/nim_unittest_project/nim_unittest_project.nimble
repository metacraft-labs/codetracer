version       = "0.1.0"
author        = "CodeTracer"
description   = "ct-test Nim unittest discovery fixture"
license       = "MIT"
srcDir        = "src"

task test, "Run fixture tests":
  exec "nim c -r tests/test_sample.nim"
