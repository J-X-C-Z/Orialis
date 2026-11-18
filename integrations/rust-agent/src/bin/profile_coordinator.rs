use anyhow::{Context, Result, ensure};
use clap::Parser;
use hermes_rust_core::profile_coordinator::{self, CoordinatorConfig};
use std::{io::Read, path::PathBuf};
#[derive(Parser)]
#[command(about = "Explicit native Agent database ↔ curated profile ↔ sync companion cycle")]
struct Args {
    #[arg(long)]
    config: PathBuf,
}
fn execute(args: Args) -> Result<i32> {
    let file = std::fs::File::open(args.config)?;
    ensure!(
        file.metadata()?.is_file(),
        "configuration must be a regular file"
    );
    let mut bytes = Vec::new();
    file.take(128 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 128 * 1024, "configuration exceeds 128 KiB");
    let config: CoordinatorConfig =
        serde_json::from_slice(&bytes).context("invalid coordinator configuration")?;
    let report = profile_coordinator::run(&config)?;
    println!("{}", serde_json::to_string(&report)?);
    Ok(report.exit_code())
}
fn main() {
    match execute(Args::parse()) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("{error:#}");
            std::process::exit(1);
        }
    }
}
