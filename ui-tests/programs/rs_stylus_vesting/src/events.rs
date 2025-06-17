use stylus_sdk::alloy_primitives::{Address, U256};
use stylus_sdk::event;

/// Event emitted when a new schedule is created.
#[event]
pub struct ScheduleCreated {
    pub schedule_id: U256,
    pub beneficiary: Address,
    pub amount: U256,
}

/// Event emitted when tokens are released.
#[event]
pub struct TokensReleased {
    pub schedule_id: U256,
    pub beneficiary: Address,
    pub amount: U256,
}

/// Event emitted when a schedule is revoked.
#[event]
pub struct ScheduleRevoked {
    pub schedule_id: U256,
}
