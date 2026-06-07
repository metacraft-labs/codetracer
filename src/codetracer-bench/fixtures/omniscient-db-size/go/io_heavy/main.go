// omniscient-db-size / go / io_heavy
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	scratch, err := os.MkdirTemp("", "ct-bench-io-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(scratch)
	total := 0
	for i := 0; i < 64; i++ {
		p := filepath.Join(scratch, fmt.Sprintf("chunk_%02d.bin", i))
		payload := strings.Repeat("abcdefgh", i+1)
		if err := os.WriteFile(p, []byte(payload), 0o600); err != nil {
			panic(err)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			panic(err)
		}
		total += len(data)
	}
	fmt.Println(total)
}
