// Account-related functions
pub fn validate_balance(balance: Field, transaction_amount: Field) -> Field {
    // Ensure balance is greater than or equal to transaction amount (cast to integers for comparison)
    assert(balance as i32 >= transaction_amount as i32);

    // Return the balance (no early return)
    balance
}

pub fn verify_identity(account_hash: pub Field, provided_hash: Field) -> Field {
    // Ensure the provided account hash matches the stored hash
    assert(account_hash == provided_hash);

    // Return the account hash (no early return)
    account_hash
}
