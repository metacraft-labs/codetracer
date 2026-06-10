package main

import "core:fmt"
import "core:os"

add :: proc(a, b: int) -> int {
  return a + b
}

main :: proc() {
  if add(2, 3) != 5 {
    os.exit(1)
  }
  fmt.println("odin fixture passed")
}
