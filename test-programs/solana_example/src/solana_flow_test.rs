// Solana flow test program (canonical computation with helper calls
// and conditional branching for calltrace / branch-coverage testing).

/// Helper: add two u64 values (exercises calltrace).
fn add(a: u64, b: u64) -> u64 {
    a + b
}

/// Helper: double a value via multiplication.
fn double(n: u64) -> u64 {
    n * 2
}

fn process_instruction() -> u64 {
    let a: u64 = 10;
    let b: u64 = 32;
    let sum_val: u64 = add(a, b);           // 42
    let doubled: u64 = double(sum_val);      // 84
    let final_result: u64 = add(doubled, a); // 94

    // Conditional branch for branch-coverage testing.
    let label: u64 = if final_result > 50 { 1 } else { 0 };
    label
}

// The SBF program around it: `cargo build-sbf` compiles this crate for the
// Solana runtime, whose entrypoint runs the flow above once.
#[cfg(target_os = "solana")]
use solana_program::{account_info::AccountInfo, entrypoint, entrypoint::ProgramResult, msg, pubkey::Pubkey};

#[cfg(target_os = "solana")]
entrypoint!(run);

#[cfg(target_os = "solana")]
fn run(_program_id: &Pubkey, _accounts: &[AccountInfo], _data: &[u8]) -> ProgramResult {
    let label = process_instruction();
    msg!("label: {}", label);
    Ok(())
}
