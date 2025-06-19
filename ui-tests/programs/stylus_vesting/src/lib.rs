#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    msg,
    prelude::*,
    storage::{StorageAddress, StorageMap, StorageU256, StorageVec},
};

mod vesting;
mod events;
mod errors;

use vesting::VestingSchedule;
use events::*;
use errors::*;



sol_storage! {
    #[entrypoint]
    pub struct VestingContract {
        StorageAddress owner;
        StorageAddress token;
        StorageMap<U256, VestingSchedule> schedules;
        StorageMap<Address, StorageVec<U256>> beneficiary_schedules;
        StorageU256 next_schedule_id;
    }
}

#[public]
impl VestingContract {
    pub fn init(&mut self, token_address: Address) {
        self.owner.set(msg::sender());
        self.token.set(token_address);
        self.next_schedule_id.set(U256::ZERO);
    }

    pub fn create_schedule(
        &mut self,
        beneficiary: Address,
        start_time: u64,
        duration_seconds: u64,
        cliff_seconds: u64,
        amount: U256,
        revocable: bool,
    ) {
        if msg::sender() != self.owner.get() {
            panic!(NotOwner());
        }
        if duration_seconds == 0 || cliff_seconds > duration_seconds {
            panic!(InvalidDuration());
        }
        if start_time < block::timestamp() {
            panic!(TimestampError());
        }
        let schedule_id = self.next_schedule_id.get();
        let schedule = VestingSchedule {
            beneficiary,
            start_time,
            duration_seconds,
            cliff_seconds,
            total_amount: amount,
            released_amount: U256::ZERO,
            is_revocable: revocable,
        };
        self.schedules.insert(schedule_id, schedule.clone());
        let mut vec = self
            .beneficiary_schedules
            .setter(beneficiary);
        vec.push(schedule_id);
        self.next_schedule_id.set(schedule_id + U256::from(1u8));
        evm::log(ScheduleCreated {
            schedule_id,
            beneficiary,
            amount,
        });
    }

    pub fn compute_releasable_amount(&self, schedule_id: U256) -> U256 {
        let schedule = self.schedules.get(schedule_id);
        if schedule.duration_seconds == 0 {
            panic!(ScheduleNotFound());
        }
        let now = block::timestamp();
        if now < schedule.start_time + schedule.cliff_seconds {
            return U256::ZERO;
        }
        let vested = if now >= schedule.start_time + schedule.duration_seconds {
            schedule.total_amount
        } else {
            let elapsed = now - schedule.start_time;
            (schedule.total_amount * U256::from(elapsed)) / U256::from(schedule.duration_seconds)
        };
        if vested <= schedule.released_amount {
            U256::ZERO
        } else {
            vested - schedule.released_amount
        }
    }

    pub fn release(&mut self, schedule_id: U256) {
        let mut schedule = self.schedules.setter(schedule_id);
        let releasable = self.compute_releasable_amount(schedule_id);
        if releasable == U256::ZERO {
            panic!("Nothing to release");
        }
        schedule.released_amount = schedule.released_amount + releasable;
        evm::log(TokensReleased {
            schedule_id,
            beneficiary: schedule.beneficiary,
            amount: releasable,
        });
    }

    pub fn release_all_for_beneficiary(&mut self, beneficiary: Address) {
        let mut ids = self.beneficiary_schedules.getter(beneficiary);
        let len = ids.len();
        for i in 0..len {
            let id = ids.get(i).unwrap();
            self.release(id);
        }
    }


    pub fn revoke(&mut self, schedule_id: U256) {
        if msg::sender() != self.owner.get() {
            panic!("Not owner");
        }
        let mut schedule = self.schedules.setter(schedule_id);
        if schedule.duration_seconds == 0 {
            panic!("Schedule not found");
        }
        if !schedule.is_revocable {
            panic!("Not revocable");
        }
        let releasable = self.compute_releasable_amount(schedule_id);
        let _unvested = schedule.total_amount - schedule.released_amount - releasable;
        schedule.total_amount = schedule.released_amount + releasable;
        evm::log(ScheduleRevoked { schedule_id });
    }
}
