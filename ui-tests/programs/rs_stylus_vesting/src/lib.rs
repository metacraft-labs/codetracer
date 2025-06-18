#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    block, evm, msg, prelude::*, storage::StorageAddress,
};
use alloy_sol_types::sol;

mod erc20; // reuse erc20 implementation from StylusPencil
use erc20::*;

sol_storage! {
    /// Individual vesting schedule information
    pub struct VestingSchedule {
        address beneficiary;
        uint256 total_amount;
        uint256 released;
        uint256 start_timestamp;
        uint256 duration;
        bool revocable;
        bool revoked;
    }
}

sol_storage! {
    #[entrypoint]
    /// Simple token vesting contract used for testing
    struct VestingContract {
        /// Map schedule id to its data
        mapping(uint256 => VestingSchedule) schedules;
        /// Beneficiary to schedule list mapping
        mapping(address => uint256[]) beneficiary_schedules;
        /// Token that will be vested
        StorageAddress token_address;
        /// Counter for generating schedule ids
        uint256 next_id;
        /// Owner of the contract
        Address owner;
    }
}

sol! {
    event TokensReleased(uint256 indexed schedule_id, address indexed beneficiary, uint256 amount);

    error NotOwner();
    error ScheduleNotFound();
    error NothingToRelease();
    error NotRevocable();
}

#[public]
impl VestingContract {
    /// Initializes the contract with the address of the token to vest.
    pub fn init(&mut self, token: Address) {
        if self.owner.get() != Address::ZERO {
            panic!("already initialized");
        }
        self.owner.set(msg::sender());
        self.token_address.set(token.into());
    }

    /// Creates a new vesting schedule and returns its identifier.
    pub fn create_schedule(
        &mut self,
        beneficiary: Address,
        amount: U256,
        start_timestamp: U256,
        duration: U256,
        revocable: bool,
    ) -> U256 {
        if msg::sender() != self.owner.get() {
            panic!("NotOwner");
        }
        if duration.is_zero() {
            panic!("duration cannot be zero");
        }

        let id = self.next_id.get();
        self.next_id.set(id + U256::from(1u8));

        self.schedules.insert(
            id,
            VestingSchedule {
                beneficiary,
                total_amount: amount,
                released: U256::ZERO,
                start_timestamp,
                duration,
                revocable,
                revoked: false,
            },
        );

        let mut list = self.beneficiary_schedules.setter(beneficiary);
        let mut v = list.get();
        v.push(id);
        list.set(v);

        id
    }

    /// Computes the releasable amount for a schedule.
    pub fn compute_releasable(&self, schedule_id: U256) -> U256 {
        let schedule = self.schedules.get(schedule_id);
        if schedule.duration.is_zero() {
            return U256::ZERO;
        }

        let mut vested = U256::ZERO;
        let current = block::timestamp();
        if current >= schedule.start_timestamp {
            let elapsed = current - schedule.start_timestamp;
            vested = if elapsed >= schedule.duration {
                schedule.total_amount
            } else {
                schedule.total_amount * elapsed / schedule.duration
            };
        }

        if vested > schedule.released {
            vested - schedule.released
        } else {
            U256::ZERO
        }
    }

    /// Releases vested tokens for a schedule.
    pub fn release(&mut self, schedule_id: U256) {
        let releasable = self.compute_releasable(schedule_id);
        if releasable.is_zero() {
            panic!("NothingToRelease");
        }

        let mut schedule = self.schedules.setter(schedule_id);
        schedule.released.set(schedule.released.get() + releasable);

        evm::log(TokensReleased {
            schedule_id,
            beneficiary: schedule.beneficiary.get(),
            amount: releasable,
        });
    }

    /// Revokes a vesting schedule.
    pub fn revoke(&mut self, schedule_id: U256) {
        if msg::sender() != self.owner.get() {
            panic!("NotOwner");
        }

        let mut schedule = self.schedules.setter(schedule_id);
        if !schedule.revocable.get() {
            panic!("NotRevocable");
        }

        schedule.revoked.set(true);
    }
}

/// Library function for generating contract ABI when `export-abi` is enabled.
#[cfg(feature = "export-abi")]
pub fn print_abi(license: &str, pragma: &str) {
    stylus_sdk::export_abi!(license, pragma, VestingContract);
}
