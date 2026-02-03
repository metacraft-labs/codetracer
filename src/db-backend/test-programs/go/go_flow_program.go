// Simple Go program for flow/omniscience integration testing.
// This program tests that local variables inside functions can be loaded
// and that function calls (fmt.Println) are filtered out from variable lists.
//
// The computation matches the Nim and Rust flow test programs:
//   a=10, b=32, sum=42, doubled=84, finalResult=94

package main

import "fmt"

func calculateSum(a, b int) int {
	// Local variables inside a function
	sum := a + b
	doubled := sum * 2
	finalResult := doubled + 10
	fmt.Println("Sum:", sum)
	fmt.Println("Doubled:", doubled)
	fmt.Println("Final:", finalResult)
	return finalResult
}

func main() {
	// Local variables in main
	x := 10
	y := 32
	result := calculateSum(x, y)
	fmt.Println("Result:", result)
}
