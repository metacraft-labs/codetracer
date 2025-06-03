use std::error::Error;
use std::fs;
use std::io::{self};
use std::time::Duration;

use crossterm::event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::Terminal;

struct App {
    lines: Vec<String>,
    scroll: u16,
}

impl App {
    fn new(file_path: &str) -> Result<Self, Box<dyn Error>> {
        let content = fs::read_to_string(file_path)?;
        let lines = content.lines().map(|l| l.to_string()).collect();
        Ok(Self { lines, scroll: 0 })
    }

    fn scroll_up(&mut self) {
        if self.scroll > 0 {
            self.scroll -= 1;
        }
    }

    fn scroll_down(&mut self) {
        self.scroll = self.scroll.saturating_add(1);
    }
}

use ratatui::Frame;

fn ui(f: &mut Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(70), Constraint::Percentage(30)].as_ref())
        .split(f.area());

    let text = app.lines.join("\n");
    let editor = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL).title("Editor"));
    f.render_widget(editor.scroll((app.scroll, 0)), chunks[0]);

    let locals = Paragraph::new("a = 1\nb = 2")
        .block(Block::default().borders(Borders::ALL).title("Locals"));
    f.render_widget(locals, chunks[1]);
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: simple-tui <file>");
        std::process::exit(1);
    }
    let mut app = App::new(&args[1])?;

    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    loop {
        terminal.draw(|f| ui(f, &app))?;

        if event::poll(Duration::from_millis(200))? {
            if let Event::Key(key) = event::read()? {
                match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Down => app.scroll_down(),
                    KeyCode::Up => app.scroll_up(),
                    _ => {}
                }
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
    Ok(())
}

