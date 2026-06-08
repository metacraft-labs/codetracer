// omniscient-db-size / solana / short_loop
//
// Real Solana SBF program. Compiled with `cargo-build-sbf` to produce
// the ELF `.so` that the recorder consumes. The non-Solana build is a
// plain Rust library so cargo-check / host-target builds still pass.

#[cfg(target_os = "solana")]
use solana_program_entrypoint::entrypoint;
#[cfg(target_os = "solana")]
use solana_account_info::AccountInfo;
#[cfg(target_os = "solana")]
use solana_program_error::ProgramResult;
#[cfg(target_os = "solana")]
use solana_pubkey::Pubkey;

#[cfg(target_os = "solana")]
entrypoint!(process_instruction);

#[cfg(target_os = "solana")]
fn process_instruction(
    _program_id: &Pubkey,
    _accounts: &[AccountInfo],
    _instruction_data: &[u8],
) -> ProgramResult {
    let mut total: u64 = 0;
    let mut i: u64 = 0;
    while i < 100 {
        total = total + i * 2;
        i += 1;
    }
    solana_msg::msg!("{}", total);
    Ok(())
}

#[cfg(not(target_os = "solana"))]
pub fn compute() -> u64 {
    let mut total: u64 = 0;
    let mut i: u64 = 0;
    while i < 100 {
        total = total + i * 2;
        i += 1;
    }
    total
}
