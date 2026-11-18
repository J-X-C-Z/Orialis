//! Explicit, dry-run-first Hermes profile migration. No automatic discovery.
use anyhow::{Context, Result, ensure};
use clap::{Args, Parser, Subcommand};
use hermes_rust_core::migration::{PathReview, SourceOptions, inspect_source};
use std::{
    fs::OpenOptions,
    io::{Read, Write},
    path::PathBuf,
};

#[derive(Parser)]
#[command(
    about = "Explicit Hermes memory/history migration. Preview first; apply requires that reviewed JSON."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Read-only inspection. Prints a redacted JSON review; never creates or writes the target.
    Preview(Selection),
    /// Apply exactly the source/target state approved in a previous preview JSON.
    Apply {
        #[command(flatten)]
        selection: Selection,
        /// Path to the JSON emitted by preview. No implicit confirmation or discovery.
        #[arg(long)]
        review: PathBuf,
    },
}
#[derive(Args)]
struct Selection {
    /// Explicit Hermes profile directory, owned and private (normally 0700).
    #[arg(long)]
    profile: PathBuf,
    /// Explicit destination Store database; its private parent must already exist.
    #[arg(long)]
    target: PathBuf,
    #[arg(long, default_value_t = 2200)]
    memory_char_limit: usize,
    #[arg(long, default_value_t = 1375)]
    user_char_limit: usize,
    /// Maximum bytes per source or copied destination file.
    #[arg(long, default_value_t = 512 * 1024 * 1024)]
    max_file_bytes: u64,
    /// Maximum rows per imported source table.
    #[arg(long, default_value_t = 250_000)]
    max_rows: usize,
    /// Maximum decoded source metadata bytes.
    #[arg(long, default_value_t = 256 * 1024 * 1024)]
    max_decoded_bytes: usize,
}
impl Selection {
    fn options(&self) -> SourceOptions {
        let mut options = SourceOptions::new(&self.profile);
        options.memory_char_limit = self.memory_char_limit;
        options.user_char_limit = self.user_char_limit;
        options.max_file_bytes = self.max_file_bytes;
        options.max_rows = self.max_rows;
        options.max_decoded_bytes = self.max_decoded_bytes;
        options
    }
}
fn read_review(path: &PathBuf) -> Result<PathReview> {
    let meta = std::fs::symlink_metadata(path).context("cannot inspect the reviewed JSON file")?;
    ensure!(
        meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= 64 * 1024,
        "review must be a regular non-symlink JSON file no larger than 64 KiB"
    );
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        ensure!(
            meta.uid() == unsafe { libc::geteuid() }
                && meta.nlink() == 1
                && meta.mode() & 0o022 == 0,
            "review must be current-user-owned, single-linked, and not writable by other users"
        );
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options
        .open(path)
        .context("cannot read the reviewed JSON file")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let opened = file
            .metadata()
            .context("cannot inspect the opened review file")?;
        ensure!(
            opened.dev() == meta.dev() && opened.ino() == meta.ino(),
            "review file changed while opening"
        );
    }
    let mut bytes = Vec::new();
    file.take(64 * 1024 + 1)
        .read_to_end(&mut bytes)
        .context("cannot read the reviewed JSON file")?;
    ensure!(bytes.len() <= 64 * 1024, "review JSON size limit exceeded");
    serde_json::from_slice(&bytes)
        .context("review JSON has an invalid format; use unmodified preview output")
}
fn run(cli: Cli) -> Result<()> {
    let output = match cli.command {
        Command::Preview(selection) => {
            let plan = inspect_source(selection.options()).context("source inspection failed; check the explicit profile, ownership, encoding and database consistency")?;
            let review = plan.preview_path(&selection.target).context("destination preview failed; check the explicit path, private permissions, Store schema and writer activity")?;
            serde_json::to_value(review)?
        }
        Command::Apply { selection, review } => {
            let reviewed = read_review(&review)?;
            let plan = inspect_source(selection.options()).context("source inspection failed; check the explicit profile and stop its writer before retrying")?;
            let report = plan.apply_path(&selection.target, &reviewed)
                .context("import rejected or failed; source/target may have changed, permissions may be unsafe, or the review may name another target; create a new preview before retrying")?;
            serde_json::json!({"status":"completed","already_applied":report.already_applied,"report":report})
        }
    };
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer_pretty(&mut out, &output)?;
    writeln!(out)?;
    Ok(())
}
fn main() -> std::process::ExitCode {
    match run(Cli::parse()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            // Only the outer, fixed contextual error is emitted. Never include
            // chained parser/SQLite details that could echo private source data.
            eprintln!("{}", serde_json::json!({"error":error.to_string()}));
            std::process::ExitCode::FAILURE
        }
    }
}
