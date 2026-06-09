// P4 GUI-ops latency fixture (Go).  Mirrors fixtures/gui-ops/python/main.py.
package main

import "fmt"

func fold(x, y int) int {
	return x*31 + y
}

func main() {
	a := 1
	b := a + 2
	c := b * 3
	d := c + 10
	e := fold(d, 7)
	fmt.Println(e)
}
