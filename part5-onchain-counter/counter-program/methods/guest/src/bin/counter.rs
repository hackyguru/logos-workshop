//! On-chain counter — Part 5 of the Logos workshop.
//!
//! This is the bare-minimum SPEL program: one PDA holds a single u64, and
//! there's one instruction that increments it. Everyone who runs the plugin
//! against the same sequencer sees the same count.
//!
//! If you've read whisper-wall's guest program, this is that with every
//! payment/privacy/admin feature stripped out. Left behind: the `#[account_type]`
//! state struct, the `#[lez_program]` module with `#[instruction]` functions,
//! and the PDA seed pattern (`literal("counter")`).
//!
//! Structure we keep:
//! * `CounterState`  — the struct borrowed onto the PDA's 128-byte data area.
//! * `initialize`    — first-time setup: claims the PDA, sets count = 0.
//! * `increment`     — adds 1 to the counter. No tip, no auth check — anyone can.
//! * `read`          — no-op; exists so `spel inspect <pda> --type CounterState`
//!                     can decode the current value right after it runs.

#![no_main]

use spel_framework::prelude::*;

risc0_zkvm::guest::entry!(main);

/// The counter's on-chain state. `#[account_type]` at file top-level registers
/// it in the IDL so `spel inspect <counter-pda> --type CounterState` knows how
/// to decode it. Must NOT live inside the `mod counter { … }` block — the IDL
/// generator only scans file-level items.
#[account_type]
#[derive(Debug, Clone, Default, BorshSerialize, BorshDeserialize)]
pub struct CounterState {
    pub count: u64,
}

#[lez_program]
mod counter {
    #[allow(unused_imports)]
    use super::*;

    /// Claim the counter PDA and zero it. Only succeeds the first time —
    /// subsequent calls hit the SPEL-level "account already initialised" guard.
    #[instruction]
    pub fn initialize(
        #[account(init, pda = literal("counter"))]
        mut state: AccountWithMetadata,
        #[account(signer)]
        signer: AccountWithMetadata,
    ) -> SpelResult {
        let initial = CounterState { count: 0 };
        let bytes = borsh::to_vec(&initial).map_err(|e| SpelError::SerializationError {
            message: e.to_string(),
        })?;
        state.account.data = bytes.try_into().unwrap();

        Ok(SpelOutput::execute(vec![state, signer], vec![]))
    }

    /// Read the current state, bump by 1, write it back.
    ///
    /// Because the counter PDA is owned by *this* program (claimed via
    /// `#[account(init)]` in `initialize`), we're allowed to mutate its
    /// `data` directly in the post-state. Anyone can call this — there's
    /// no signer auth check, just the standard "you must sign the TX" the
    /// runtime enforces via `#[account(signer)]` below.
    #[instruction]
    pub fn increment(
        #[account(mut, pda = literal("counter"))]
        mut state: AccountWithMetadata,
        #[account(signer)]
        signer: AccountWithMetadata,
    ) -> SpelResult {
        let data: Vec<u8> = state.account.data.clone().into();
        let mut current: CounterState =
            borsh::from_slice(&data).map_err(|e| SpelError::DeserializationError {
                account_index: 0,
                message: e.to_string(),
            })?;

        current.count = current.count.saturating_add(1);

        let bytes = borsh::to_vec(&current).map_err(|e| SpelError::SerializationError {
            message: e.to_string(),
        })?;
        state.account.data = bytes.try_into().unwrap();

        Ok(SpelOutput::execute(vec![state, signer], vec![]))
    }

    /// No-op read. The account goes in, unchanged, and comes out. Exists so
    /// `spel inspect <pda> --type CounterState` can decode the live bytes
    /// after the TX. Mirrors whisper-wall's `reveal` pattern.
    #[instruction]
    pub fn read(
        #[account(pda = literal("counter"))]
        state: AccountWithMetadata,
    ) -> SpelResult {
        Ok(SpelOutput::execute(vec![state], vec![]))
    }
}
