// multi_return_with_err — Go
//
// Go's `a, err := foo()` produces two ReturnCapture hops — one for
// each LHS target. The classifier walks the destructuring assignment
// and emits a ReturnCapture for each target whose source is the same
// call expression (spec §7.2 Go row).
//
// Expected chain for `a` queried at the `fmt.Println` line:
//
//   hop 0: target=a          rhs=foo()   OriginKind=ReturnCapture   source_variable=foo()$0
//   hop 1: terminator=Literal(int, value=42)
package main

import "fmt"

func foo() (int, error) {
	return 42, nil
}

func main() {
	a, err := foo()
	if err != nil {
		panic(err)
	}
	fmt.Println(a)
}
