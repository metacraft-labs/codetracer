use std::error::Error;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use clap::Parser;
use schemars::schema_for;
use schemars_zod::merge_schemas;

extern crate db_backend;

use db_backend::ct_types;

/// JSON schema generator for our types used in custom ct extensions to DAP or in multiple parts of our code
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    /// path to store the json schema
    output_path: PathBuf,
}

fn main() -> Result<(), Box<dyn Error>> {
    let cli = Args::parse();

    let mut schema = merge_schemas(
        vec![
            schema_for!(task::CoreTrace),
            schema_for!(task::ConfigureArg),
            schema_for!(task::CtLoadLocalsArguments),
            schema_for!(task::CtLoadLocalsResponseBody),
            schema_for!(task::UpdateTableArgs),
            schema_for!(task::CtUpdatedTableResponseBody),
        ]
        .into_iter(),
    );
    // copied from DAP json schema
    schema.meta_schema = Some("http://json-schema.org/draft-04/schema#".to_string());
    // description: "ct types";?

    let json_text = serde_json::to_string_pretty(&schema)?;
    fs::write(cli.output_path, json_text)?;

    Ok(())
}
