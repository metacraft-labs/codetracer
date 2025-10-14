mod subcommands;

use clap::{Parser, Subcommand};

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

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Output a pre-defined secret message.
    Record,

    // TODO: list all subcommands
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
        _ => unimplemented!(),
    }
}
