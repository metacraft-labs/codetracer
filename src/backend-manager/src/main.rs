mod backend_manager;
mod dap_parser;
mod errors;

use std::error::Error;


#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    Ok(())
}
