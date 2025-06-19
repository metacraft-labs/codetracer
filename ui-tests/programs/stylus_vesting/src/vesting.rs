use stylus_sdk::{alloy_primitives::{Address, U256}, prelude::*};

sol_storage! {
    pub struct VestingSchedule {
        Address beneficiary;
        u64 start_time;
        u64 duration_seconds;
        u64 cliff_seconds;
        U256 total_amount;
        U256 released_amount;
        bool is_revocable;
    }
}
