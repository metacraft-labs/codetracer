// parameter_pass — Go
package main

import "fmt"

func receive(p int) {
	local := p
	fmt.Println(local)
}

func main() {
	value := 7
	receive(value)
}
