// Package sample exercises the Go tokenizer.
package main

import (
	"fmt"
	"strings"
)

/* A block comment
   across lines. */
type Shape interface {
	Area() float64
}

type Rect struct {
	W, H float64
}

func (r Rect) Area() float64 { return r.W * r.H }

func main() {
	shapes := []Shape{Rect{W: 2, H: 3.5}}
	total := 0.0
	for _, s := range shapes {
		total += s.Area()
	}
	raw := `a raw
string`
	ch := 'x'
	hex := 0x1f
	if total > 1e2 || len(raw) != 0 {
		fmt.Println(strings.ToUpper("big"), ch, hex)
	}
	defer fmt.Printf("%.2f\n", total)
	var m = map[string]int{"a": 1}
	go func() { m["b"] = 2 }()
}
