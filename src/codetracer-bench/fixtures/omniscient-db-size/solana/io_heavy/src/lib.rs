// omniscient-db-size / solana / io_heavy
//
// Real Solana SBF program.  Solana programs don't have host file I/O;
// the analogue used here is a fixed-capacity byte buffer that grows
// through nested writes — same shape as Python / Ruby io_heavy but
// adapted to the SBF VM's no-heap-syscalls model.

#[cfg(target_os = "solana")]
use solana_program_entrypoint::entrypoint;
#[cfg(target_os = "solana")]
use solana_account_info::AccountInfo;
#[cfg(target_os = "solana")]
use solana_program_error::ProgramResult;
#[cfg(target_os = "solana")]
use solana_pubkey::Pubkey;

fn compute() -> u32 {
    let mut buf = [0u8; 1024];
    let mut len: u32 = 0;
    let mut i: u32 = 0;
    while i < 16 {
        let mut j: u32 = 0;
        while j < (i + 1) * 8 && len < 1024 {
            buf[len as usize] = (b'a' + (j as u8 % 8)) as u8;
            len += 1;
            j += 1;
        }
        i += 1;
    }
    let mut sum: u32 = 0;
    let mut k: u32 = 0;
    while k < len {
        sum = sum.wrapping_add(buf[k as usize] as u32);
        k += 1;
    }
    sum
}

#[cfg(target_os = "solana")]
entrypoint!(process_instruction);

#[cfg(target_os = "solana")]
fn process_instruction(
    _program_id: &Pubkey,
    _accounts: &[AccountInfo],
    _instruction_data: &[u8],
) -> ProgramResult {
    let sum = compute();
    solana_msg::msg!("{}", sum);
    Ok(())
}

#[cfg(not(target_os = "solana"))]
pub fn compute_for_host() -> u32 {
    compute()
}
