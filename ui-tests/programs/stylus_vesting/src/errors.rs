use alloy_sol_types::sol;

sol! {
    error NotOwner();
    error ScheduleNotFound();
    error NotRevocable();
    error InvalidDuration();
    error NothingToRelease();
    error TimestampError();
}
