#	LLVM WebAssembly assembly — the multi-value half of `pair_stats`.
#
#	Assembled by `regenerate.sh` with
#
#	    clang --target=wasm32-unknown-unknown -mmultivalue -c wrap.s -o wrap.o
#
#	and linked into the Rust cdylib. It exists for one reason: `rustc`
#	cannot emit a WebAssembly function with more than one result. Every
#	wasm ABI it supports on stable returns an aggregate through a hidden
#	pointer argument, so `extern "C" fn(u32) -> (u32, u32)` compiles to
#	`(i32, i32, i32) -> ()` and the boundary carries no result tuple at
#	all. Multi-value is reachable only from this level.
#
#	Nothing is computed here. The wrapper calls `sample_packed` — the
#	Rust function in `lib.rs`, which is where the state and the DWARF
#	are — and splits its `i64` into the high and low halves the declared
#	`(i32, i32)` result expects. Nine instructions, no branches, no
#	memory access.
#
#	`sample_packed` is declared, not defined, here; `.functype` is how
#	the LLVM WebAssembly assembler is told an external symbol's
#	signature.

	.text

	.functype	sample_packed (i32) -> (i64)

	.globl	sample_pair
	.type	sample_pair,@function
sample_pair:
	.functype	sample_pair (i32) -> (i32, i32)
	.local	i64
	local.get	0
	call	sample_packed
	local.set	1
#	result 0: the window mean, the packed value's high half.
	local.get	1
	i64.const	32
	i64.shr_u
	i32.wrap_i64
#	result 1: the window peak, the packed value's low half.
	local.get	1
	i32.wrap_i64
	end_function
