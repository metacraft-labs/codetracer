// return_capture — Go
package main

import "fmt"

func compute() int {
	a := 3
	b := 4
	return a + b
}

func main() {
	captured := compute()
	fmt.Println(captured)
}
