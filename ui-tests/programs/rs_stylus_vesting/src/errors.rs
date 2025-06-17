use stylus_sdk::solidity::SolError;

/// Caller is not the contract owner.
#[derive(Debug, SolError)]
#[sol(error_name = "NotOwner")]
pub struct NotOwner;

/// Schedule not found for a given ID.
#[derive(Debug, SolError)]
#[sol(error_name = "ScheduleNotFound")]
pub struct ScheduleNotFound;

/// Attempted to revoke a non-revocable schedule.
#[derive(Debug, SolError)]
#[sol(error_name = "NotRevocable")]
pub struct NotRevocable;

/// Invalid vesting duration or cliff.
#[derive(Debug, SolError)]
#[sol(error_name = "InvalidDuration")]
pub struct InvalidDuration;

/// No tokens are available for release.
#[derive(Debug, SolError)]
#[sol(error_name = "NothingToRelease")]
pub struct NothingToRelease;

/// Start timestamp cannot be in the past.
#[derive(Debug, SolError)]
#[sol(error_name = "TimestampError")]
pub struct TimestampError;
