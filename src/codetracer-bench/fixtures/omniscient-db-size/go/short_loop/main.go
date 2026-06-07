// omniscient-db-size / go / short_loop
package main

import "fmt"

func main() {
	total := 0
	for i := 0; i < 100; i++ {
		total = total + i*2
	}
	fmt.Println(total)
}
