/// Generate IDL JSON for the counter program.
///
/// Usage:
///   cargo run --bin generate_idl > counter-idl.json
///
/// Note: the Makefile's `make idl` target uses `spel generate-idl` directly
/// instead of this binary because the `generate_idl!` proc macro doesn't
/// pick up `#[account_type]` markers (SPEL #141). Keeping this file for
/// symmetry with whisper-wall.

spel_framework::generate_idl!("../methods/guest/src/bin/counter.rs");
