//!
//! Stylus Hello World
//!
//! The following contract implements the Counter example from Foundry.
//!
//! ```solidity
//! contract Counter {
//!     uint256 public number;
//!     function setNumber(uint256 newNumber) public {
//!         number = newNumber;
//!     }
//!     function increment() public {
//!         number++;
//!     }
//! }
//! ```
//!
//! The program is ABI-equivalent with Solidity, which means you can call it from both Solidity and Rust.
//! To do this, run `cargo stylus export-abi`.
//!
//! Note: this code is a template-only and has not been audited.
//!
// Allow `cargo stylus export-abi` to generate a main function.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(not(any(test, feature = "export-abi")), no_std)]

#[macro_use]
extern crate alloc;

use alloc::vec::Vec;

use alloy_sol_types::sol;
/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::{alloy_primitives::U256, prelude::*};

// Define some persistent storage using the Solidity ABI.
// `Counter` will be the entrypoint.
sol_storage! {
    pub struct Fund {
        bool incoming;
        /// In wei
        uint256 amount;
    }

    #[entrypoint]
    pub struct Counter {
        Fund[] funds;
    }
}

sol! {
    event Pari(uint256 pari);
}

/// Declare that `Counter` is a contract with the following external methods.
#[public]
impl Counter {
    pub fn fund(&mut self, pari: U256) {
        let mut new_fund = self.funds.grow();
        new_fund.incoming.set(true);
        new_fund.amount.set(pari);
    }

    pub fn withdraw(&mut self, pari: U256) {
        let mut new_fund = self.funds.grow();
        new_fund.incoming.set(false);
        new_fund.amount.set(pari);
    }

    pub fn large_incomes(&self, treshold: U256) -> U256 {
        let mut res = U256::ZERO;

        let n = self.funds.len();

        for idx in 0..n {
            let fund = self.funds.get(idx).expect("fund exists");
            let amount = fund.amount.get();

            if fund.incoming.get() && amount >= treshold {
                res += amount;
            }
        }
        res
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_counter() {
        use stylus_sdk::testing::*;
        let vm = TestVM::default();
        let mut contract = Counter::from(&vm);

        contract.fund(U256::from(2));
        contract.fund(U256::from(3));
        contract.fund(U256::from(5));
        dbg!(contract.large_incomes(U256::from(3)));
    }
}
