use stylus_sdk::prelude::*;

sol_storage! {
    pub struct VestingSchedule {
        address beneficiary;
        uint256 start_time;
        uint256 duration_seconds;
        uint256 cliff_seconds;
        uint256 total_amount;
        uint256 released_amount;
        bool is_revocable;
    }
}
