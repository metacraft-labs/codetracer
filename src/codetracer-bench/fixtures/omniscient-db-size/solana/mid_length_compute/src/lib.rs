// omniscient-db-size / solana / mid_length_compute
//
// Real Solana SBF program.  Real fold over 64×64 byte chunks, 200
// outer rounds — comparable shape to the Python / Ruby / Nim
// mid_length_compute fixtures, but adapted to the SBF VM's compute-
// unit budget (the recorder's `execute_with_tracing` defaults to
// 1_000_000 CU and Solana's per-instruction CU charges are higher
// than the Sierra runner's gas).

#[cfg(target_os = "solana")]
use solana_program_entrypoint::entrypoint;
#[cfg(target_os = "solana")]
use solana_account_info::AccountInfo;
#[cfg(target_os = "solana")]
use solana_program_error::ProgramResult;
#[cfg(target_os = "solana")]
use solana_pubkey::Pubkey;

fn fold(state: &mut [u8; 32], chunk: &[u8; 64]) {
    let mut i = 0usize;
    while i < 32 {
        state[i] ^= chunk[i].wrapping_add(i as u8);
        state[i] = state[i].wrapping_mul(31).wrapping_add(7);
        i += 1;
    }
}

fn compute() -> u32 {
    let mut state = [0u8; 32];
    let mut chunks = [[0u8; 64]; 16];
    let mut i = 0usize;
    while i < 16 {
        let mut j = 0usize;
        while j < 64 {
            chunks[i][j] = ((i + j) % 251) as u8;
            j += 1;
        }
        i += 1;
    }
    let mut accum: u32 = 0;
    let mut r = 0;
    while r < 8 {
        let mut c = 0usize;
        while c < 16 {
            fold(&mut state, &chunks[c]);
            accum = accum.wrapping_add(state[0] as u32) & 0xFFFF;
            c += 1;
        }
        r += 1;
    }
    accum
}

#[cfg(target_os = "solana")]
entrypoint!(process_instruction);

#[cfg(target_os = "solana")]
fn process_instruction(
    _program_id: &Pubkey,
    _accounts: &[AccountInfo],
    _instruction_data: &[u8],
) -> ProgramResult {
    let accum = compute();
    solana_msg::msg!("{}", accum);
    Ok(())
}

#[cfg(not(target_os = "solana"))]
pub fn compute_for_host() -> u32 {
    compute()
}
