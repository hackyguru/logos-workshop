//! IDL-driven CLI wrapper. `spel::run()` loads `spel.toml`, reads the IDL,
//! and exposes each `#[instruction]` as a subcommand at runtime.
//!
//! Examples:
//!   cargo run --bin counter_cli -- initialize --signer <ID>
//!   cargo run --bin counter_cli -- increment  --signer <ID>
//!   cargo run --bin counter_cli -- read

#[tokio::main]
async fn main() {
    spel::run().await;
}
