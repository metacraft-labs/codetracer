mod account;
mod transaction;

use crate::transaction::make_transaction;

fn main(
    sender_balance: pub Field, sender_account_hash: pub Field, sender_provided_hash: Field,
    recipient_balance: pub Field, recipient_account_hash: pub Field, recipient_provided_hash: Field,
    transaction_amount: Field
) {
    // Call the transaction function with all required arguments
    let (new_sender_balance, new_recipient_balance) = make_transaction(
        sender_balance,
        sender_account_hash,
        sender_provided_hash,
        recipient_balance,
        recipient_account_hash,
        recipient_provided_hash,
        transaction_amount
    );

    // Assert that the balances are updated correctly
    assert(new_sender_balance == sender_balance - transaction_amount);
    assert(new_recipient_balance == recipient_balance + transaction_amount);
}
