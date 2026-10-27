//! `ct-jsbound`: the boundary-recording assembler (JS-Boundary-Recording.md
//! §5.6). All of the work is in the `jsbound` library; see `jsbound::cli`.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match jsbound::cli::run(&args) {
        Ok(summary) => println!("{summary}"),
        Err(e) => {
            eprintln!("ct-jsbound: {e}");
            std::process::exit(e.exit_code());
        }
    }
}
