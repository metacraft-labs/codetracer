use stylus_sdk::alloy_primitives::{Address, U256};

/// Parameters defining a single vesting schedule.
#[derive(Clone, Default)]
pub struct VestingSchedule {
    pub beneficiary: Address,
    pub start_time: u64,
    pub duration_seconds: u64,
    pub cliff_seconds: u64,
    pub total_amount: U256,
    pub released_amount: U256,
    pub is_revocable: bool,
}
