use crate::account::{validate_balance, verify_identity};

pub fn make_transaction(
    sender_balance: Field, sender_account_hash: pub Field, sender_provided_hash: Field,
    recipient_balance: Field, recipient_account_hash: pub Field, recipient_provided_hash: Field,
    transaction_amount: Field
) -> (Field, Field) {
    // Verify sender's identity
    let _ = verify_identity(sender_account_hash, sender_provided_hash);

    // Verify recipient's identity
    let _ = verify_identity(recipient_account_hash, recipient_provided_hash);

    // Validate that the sender has enough balance
    let remaining_balance = validate_balance(sender_balance, transaction_amount);

    // Update recipient's balance (no early return)
    let updated_recipient_balance = recipient_balance + transaction_amount;

    // Return the updated balances as a tuple
    (remaining_balance, updated_recipient_balance)
}
