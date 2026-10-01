// simple_trivial_chain: a=10; b=a; c=b. The origin chain of `c` ends at a Literal.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(not(any(test, feature = "export-abi")), no_std)]

#[macro_use]
extern crate alloc;

use alloc::vec::Vec;

use stylus_sdk::prelude::*;

sol_storage! {
    #[entrypoint]
    pub struct TrivialChain {
        uint256 unused;
    }
}

#[public]
impl TrivialChain {
    pub fn compute(&self) -> u32 {
        let a: u32 = 10;
        let b: u32 = a;
        let c: u32 = b;
        core::hint::black_box(&c);
        c
    }
}
