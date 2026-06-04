// destructuring_or_index — Go
// Go uses multiple-value return assignment as its destructuring shape,
// plus slice index access.
package main

import "fmt"

func pair() (int, int) {
	return 11, 22
}

func main() {
	first, second := pair()        // multiple-value assignment ("destructure")
	arr := []int{11, 22}
	indexed := arr[1]               // index access
	fmt.Println(first, second, indexed)
}
