// go_coop_record.go — deterministic cgo Go fixture for the MCR macOS
// cooperative recorder corpus (M-GO-1, record-only).
//
// Requirements codified here (see MCR-macOS-Go-Support.milestones.org M-GO-1):
//   * empty `import "C"` forces cgo, so `go build` drives an EXTERNAL link
//     (-linkmode=external) and routes runtime syscalls through libc trampolines
//     — the surface the cooperative fishhook capture rebinds.
//   * runtime.GOMAXPROCS(1) at the very start pins the scheduler to a single P
//     so the work is single-threaded and deterministic.
//   * a fixed amount of work + a DETERMINISTIC stdout: NO time, map iteration,
//     randomness, or goroutine-ordering-dependent output.  The output is a
//     fixed string written with two os.Stdout.Write calls of known byte counts,
//     so each surfaces as an evOsWrite with a known retval (= bytes written).
//
// The two writes are:
//   1. "MCR-GO line 1\n"  -> 14 bytes
//   2. "MCR-GO line 2\n"  -> 14 bytes
// plus a fixed-count loop sum printed as a third write of a fixed string:
//   3. "sum=45\n"         -> 7 bytes
// (loop 0..9 -> 0+1+...+9 = 45, a compile-time-fixed value emitted as a
// literal-length string).

package main

/*
// (empty cgo preamble — its mere presence forces CGO_ENABLED external link)
*/
import "C"

import (
	"os"
	"runtime"
)

func main() {
	// Pin to a single OS thread / P so the recording is single-threaded and
	// deterministic (no goroutine-scheduling-dependent interleaving).
	runtime.GOMAXPROCS(1)

	// Fixed-count loop with a compile-time-known result (0+1+...+9 = 45).
	sum := 0
	for i := 0; i < 10; i++ {
		sum += i
	}

	// Deterministic stdout: three writes of fixed bytes with known counts.
	// Each is one os.Stdout.Write -> one evOsWrite with retval == len.
	os.Stdout.Write([]byte("MCR-GO line 1\n")) // 14 bytes
	os.Stdout.Write([]byte("MCR-GO line 2\n")) // 14 bytes
	if sum == 45 {
		os.Stdout.Write([]byte("sum=45\n")) // 7 bytes
	} else {
		os.Stdout.Write([]byte("sum=??\n")) // unreachable; keeps output fixed
	}
}
