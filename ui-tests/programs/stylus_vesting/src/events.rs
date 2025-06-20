use alloy_sol_types::sol;

sol! {
    event ScheduleCreated(uint256 schedule_id, address beneficiary, uint256 amount);
    event TokensReleased(uint256 schedule_id, address beneficiary, uint256 amount);
    event ScheduleRevoked(uint256 schedule_id);
}
