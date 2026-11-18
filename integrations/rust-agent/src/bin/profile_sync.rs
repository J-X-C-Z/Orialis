use clap::{Parser, Subcommand};
use hermes_rust_core::profile_sync::{self, SyncConfig};
use serde_json::json;
use std::{
    io::{self, Write},
    path::PathBuf,
};

#[derive(Parser)]
#[command(about = "Synchronize only curated Orialis profile files; no credentials or sessions")]
struct Args {
    #[command(subcommand)]
    command: Operation,
}
#[derive(Subcommand)]
enum Operation {
    Hub {
        #[arg(long)]
        store: PathBuf,
    },
    Sync {
        #[arg(long)]
        config: PathBuf,
    },
    Snapshot {
        #[arg(long)]
        profile: PathBuf,
    },
}
fn main() {
    let args = Args::parse();
    let hub = matches!(&args.command, Operation::Hub { .. });
    let result: anyhow::Result<i32> = (|| match args.command {
        Operation::Hub { store } => {
            profile_sync::serve_hub(&store, &mut io::stdin().lock(), &mut io::stdout().lock())?;
            Ok(0)
        }
        Operation::Sync { config } => {
            let config: SyncConfig = serde_json::from_slice(&std::fs::read(config)?)?;
            let outcome = profile_sync::run_sync(&config)?;
            println!("{}", serde_json::to_string(&outcome)?);
            Ok(outcome.exit_code())
        }
        Operation::Snapshot { profile } => {
            use base64::Engine as _;
            let contents = profile_sync::scan(&profile)?;
            let payload: std::collections::BTreeMap<_, _> = contents
                .iter()
                .map(|(path, data)| (path, base64::engine::general_purpose::STANDARD.encode(data)))
                .collect();
            println!(
                "{}",
                json!({"files": profile_sync::manifest(&contents), "payload": payload})
            );
            Ok(0)
        }
    })();
    match result {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            if hub {
                println!("{}", json!({"error": error.to_string()}));
                let _ = io::stdout().flush();
            } else {
                eprintln!("{error:#}");
            }
            std::process::exit(1);
        }
    }
}
