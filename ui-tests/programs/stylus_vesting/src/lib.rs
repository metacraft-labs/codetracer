#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    msg,
    prelude::*,
    storage::{StorageAddress, StorageMap, StorageU256, StorageVec},
    block,
    evm,
};

mod vesting;
mod events;


use vesting::VestingSchedule;
use events::*;



sol_storage! {
    #[entrypoint]
    pub struct VestingContract {
        StorageAddress owner;
        StorageAddress token;
        StorageMap<U256, VestingSchedule> schedules;
        StorageMap<Address, StorageVec<StorageU256>> beneficiary_schedules;
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
            panic!("NotOwner");
        }
        if duration_seconds == 0 || cliff_seconds > duration_seconds {
            panic!("InvalidDuration");
        }
        if start_time < block::timestamp() {
            panic!("TimestampError");
        }
        let schedule_id = self.next_schedule_id.get();
        let mut schedule = self.schedules.setter(schedule_id);
        schedule.beneficiary.set(beneficiary);
        schedule.start_time.set(U256::from(start_time));
        schedule.duration_seconds.set(U256::from(duration_seconds));
        schedule.cliff_seconds.set(U256::from(cliff_seconds));
        schedule.total_amount.set(amount);
        schedule.released_amount.set(U256::ZERO);
        schedule.is_revocable.set(revocable);

        let mut vec = self.beneficiary_schedules.setter(beneficiary);
        vec.push(schedule_id);
        self.next_schedule_id.set(schedule_id + U256::from(1u8));
        evm::log(ScheduleCreated {
            schedule_id,
            beneficiary,
            amount,
        });
    }

    pub fn compute_releasable_amount(&self, schedule_id: U256) -> U256 {
        let schedule = self.schedules.getter(schedule_id);
        if schedule.duration_seconds.get() == U256::ZERO {
            panic!("ScheduleNotFound");
        }
        let now = U256::from(block::timestamp());
        if now < schedule.start_time.get() + schedule.cliff_seconds.get() {
            return U256::ZERO;
        }
        let vested = if now >= schedule.start_time.get() + schedule.duration_seconds.get() {
            schedule.total_amount.get()
        } else {
            let elapsed = now - schedule.start_time.get();
            (schedule.total_amount.get() * elapsed) / schedule.duration_seconds.get()
        };
        if vested <= schedule.released_amount.get() {
            U256::ZERO
        } else {
            vested - schedule.released_amount.get()
        }
    }

    pub fn release(&mut self, schedule_id: U256) {
        let releasable = self.compute_releasable_amount(schedule_id);
        if releasable == U256::ZERO {
            panic!("Nothing to release");
        }
        let mut schedule = self.schedules.setter(schedule_id);
        let released = schedule.released_amount.get() + releasable;
        schedule.released_amount.set(released);
        let beneficiary = schedule.beneficiary.get();
        evm::log(TokensReleased {
            schedule_id,
            beneficiary,
            amount: releasable,
        });
    }

    pub fn release_all_for_beneficiary(&mut self, beneficiary: Address) {
        let ids_guard = self.beneficiary_schedules.getter(beneficiary);
        let len = ids_guard.len();
        let mut ids = Vec::with_capacity(len);
        for i in 0..len {
            if let Some(id) = ids_guard.get(i) {
                ids.push(id);
            }
        }
        drop(ids_guard);
        for id in ids {
            self.release(id);
        }
    }


    pub fn revoke(&mut self, schedule_id: U256) {
        if msg::sender() != self.owner.get() {
            panic!("Not owner");
        }
        if self.schedules.getter(schedule_id).duration_seconds.get() == U256::ZERO {
            panic!("Schedule not found");
        }
        if !self.schedules.getter(schedule_id).is_revocable.get() {
            panic!("Not revocable");
        }
        let releasable = self.compute_releasable_amount(schedule_id);
        let mut schedule = self.schedules.setter(schedule_id);
        let released = schedule.released_amount.get();
        let _unused_unvested = schedule.total_amount.get() - released - releasable;
        schedule.total_amount.set(released + releasable);
        evm::log(ScheduleRevoked { schedule_id });
    }
}
