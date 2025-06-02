use crossterm::{
    event::{self, Event as CEvent, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::io::{self, Write};

/// A very small TUI example that just prints a message and waits for `q` to quit.
fn main() -> crossterm::Result<()> {
    enable_raw_mode()?;
    execute!(io::stdout(), EnterAlternateScreen)?;

    println!("Press 'q' to exit the new TUI");

    loop {
        if let CEvent::Key(key_event) = event::read()? {
            if key_event.code == KeyCode::Char('q') {
                break;
            }
        }
    }

    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    io::stdout().flush()?;
    Ok(())
}
