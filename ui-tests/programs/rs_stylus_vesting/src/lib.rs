//! Demo Stylus vesting contract used by CodeTracer UI tests.
//! It implements token vesting logic showcasing storage access,
//! conditional branching, loops and function calls.

use stylus_sdk::prelude::*;
use stylus_sdk::storage::{StorageAddress, StorageMap, StorageU256, StorageVec};
use stylus_sdk::alloy_primitives::{Address, U256};

mod vesting;
mod events;
mod errors;

use vesting::VestingSchedule;
use events::*;
use errors::*;

#[solidity_storage]
#[entrypoint]
pub struct VestingContract {
    owner: StorageAddress,
    token: StorageAddress,
    schedules: StorageMap<U256, VestingSchedule>,
    beneficiary_schedules: StorageMap<Address, StorageVec<U256>>,
    next_schedule_id: StorageU256,
}

impl VestingContract {
    /// Initialize the contract with the ERC20 token address.
    #[external]
    pub fn init(&mut self, token_address: Address) {
        self.owner.set(msg::sender());
        self.token.set(token_address);
        self.next_schedule_id.set(U256::from(0));
    }

    /// Owner-only schedule creation.
    #[external]
    pub fn create_schedule(
        &mut self,
        beneficiary: Address,
        start_time: u64,
        duration_seconds: u64,
        cliff_seconds: u64,
        amount: U256,
        revocable: bool,
    ) -> Result<U256, SolError> {
        if msg::sender() != *self.owner {
            return Err(NotOwner.into());
        }
        if duration_seconds == 0 || cliff_seconds > duration_seconds {
            return Err(InvalidDuration.into());
        }
        if start_time < block::timestamp() {
            return Err(TimestampError.into());
        }

        let schedule_id = *self.next_schedule_id;
        self.next_schedule_id.set(schedule_id + U256::from(1));

        let schedule = VestingSchedule {
            beneficiary,
            start_time,
            duration_seconds,
            cliff_seconds,
            total_amount: amount,
            released_amount: U256::from(0),
            is_revocable: revocable,
        };

        self.schedules.insert(schedule_id, schedule.clone());
        let mut vec = self
            .beneficiary_schedules
            .get(beneficiary)
            .unwrap_or_default();
        vec.push(schedule_id);
        self.beneficiary_schedules.insert(beneficiary, vec);
        emit(ScheduleCreated {
            schedule_id,
            beneficiary,
            amount,
        });
        Ok(schedule_id)
    }

    /// Calculate releasable amount for a given schedule.
    #[view]
    pub fn compute_releasable_amount(&self, schedule_id: U256) -> Result<U256, SolError> {
        let schedule = self
            .schedules
            .get(schedule_id)
            .ok_or(ScheduleNotFound)?;

        let current = block::timestamp();
        if current < schedule.start_time + schedule.cliff_seconds {
            return Ok(U256::from(0));
        }
        if current >= schedule.start_time + schedule.duration_seconds {
            return Ok(schedule.total_amount - schedule.released_amount);
        }
        let elapsed = current - schedule.start_time;
        let vested =
            (schedule.total_amount * U256::from(elapsed)) / U256::from(schedule.duration_seconds);
        Ok(vested - schedule.released_amount)
    }

    /// Release vested tokens from a specific schedule.
    #[external]
    pub fn release(&mut self, schedule_id: U256) -> Result<(), SolError> {
        let amount = self.compute_releasable_amount(schedule_id)?;
        if amount == U256::from(0) {
            return Err(NothingToRelease.into());
        }
        let mut schedule = self
            .schedules
            .get(schedule_id)
            .ok_or(ScheduleNotFound)?;
        schedule.released_amount += amount;
        self.schedules.insert(schedule_id, schedule.clone());
        // perform token transfer
        call::transfer(*self.token, schedule.beneficiary, amount)?;
        emit(TokensReleased {
            schedule_id,
            beneficiary: schedule.beneficiary,
            amount,
        });
        Ok(())
    }

    /// Release tokens from all schedules of a beneficiary.
    #[external]
    pub fn release_all_for_beneficiary(&mut self, beneficiary: Address) -> Result<(), SolError> {
        let mut vec = self
            .beneficiary_schedules
            .get(beneficiary)
            .unwrap_or_default();
        for schedule_id in vec.iter() {
            let _ = self.release(*schedule_id);
        }
        Ok(())
    }

    /// Revoke a schedule and return unvested tokens to owner.
    #[external]
    pub fn revoke(&mut self, schedule_id: U256) -> Result<(), SolError> {
        if msg::sender() != *self.owner {
            return Err(NotOwner.into());
        }
        let mut schedule = self
            .schedules
            .get(schedule_id)
            .ok_or(ScheduleNotFound)?;
        if !schedule.is_revocable {
            return Err(NotRevocable.into());
        }

        let releasable = self.compute_releasable_amount(schedule_id)?;
        let unvested = schedule.total_amount - schedule.released_amount - releasable;
        if releasable > U256::from(0) {
            call::transfer(*self.token, schedule.beneficiary, releasable)?;
        }
        if unvested > U256::from(0) {
            call::transfer(*self.token, *self.owner, unvested)?;
        }
        schedule.released_amount += releasable;
        schedule.total_amount = schedule.released_amount;
        self.schedules.insert(schedule_id, schedule);
        emit(ScheduleRevoked { schedule_id });
        Ok(())
    }
}
