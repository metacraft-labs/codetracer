mod db;
mod lang;
mod paths;
mod subcommands;

use clap::{Parser, Subcommand};

use crate::lang::Lang;

#[derive(Debug, Parser)]
#[command(
    name = "ct",
    about = "TODO: write description",
    version,
    propagate_version = true
)]
pub struct Args {
    /// Selects which operation to perform.
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, clap::Args)]
pub struct RecordOptions {
    /// Override the language of the project. Used to determine which recorder is used.
    #[arg(short, long)]
    pub lang: Option<Lang>,

    /// Where to save the trace.
    #[arg(short, long)]
    pub output_folder: Option<String>,

    /// Path to the program to record.
    pub program: String,

    /// Arguments to pass to the program.
    pub args: Vec<String>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Record the execution of a program
    Record(RecordOptions),

    /// Lists all available external subcommands.
    List,

    /// Defer execution to an external `ct-*` binary.
    #[command(external_subcommand)]
    External(Vec<String>),
}

fn main() {
    let args = Args::parse();

    match args.command {
        Command::List => subcommands::run_list::<Args>(),
        Command::External(args) => subcommands::run_external(&args),
        Command::Record(options) => subcommands::run_record(options),
    }
}
