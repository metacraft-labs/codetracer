use std::error::Error;
use std::fs;
use std::io::{self};
use std::time::Duration;

use crossterm::event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::Terminal;

mod dap_client;
use dap_client::DapClient;

struct App {
    lines: Vec<String>,
    scroll: u16,
    dap: Option<DapClient>,
    program: String,
}

impl App {
    /// Create a new application instance.
    ///
    /// `trace_dir` is the directory containing a recorded trace. The
    /// application always opens the `trace.json` file from this directory. When
    /// a DAP server binary is provided, the DAP client is started and a launch
    /// request is sent containing our PID and the trace directory path.
    fn new(trace_dir: &str, dap_bin: Option<&str>, program: &str) -> Result<Self, Box<dyn Error>> {
        let mut dap = if let Some(bin) = dap_bin {
            Some(DapClient::start(bin)?)
        } else {
            None
        };

        if let Some(client) = dap.as_mut() {
            // Inform the DAP server about the trace we want to analyze
            client.launch(trace_dir, program)?;
        }

        let trace_file = format!("{}/trace.json", trace_dir);

        let content = if let Some(client) = dap.as_mut() {
            client.request_source(&trace_file)?
        } else {
            fs::read_to_string(&trace_file)?
        };

        let lines = content.lines().map(|l| l.to_string()).collect();
        Ok(Self {
            lines,
            scroll: 0,
            dap,
            program: program.to_string(),
        })
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
    let editor = Paragraph::new(text).block(Block::default().borders(Borders::ALL).title("Editor"));
    f.render_widget(editor.scroll((app.scroll, 0)), chunks[0]);

    let locals = Paragraph::new("a = 1\nb = 2")
        .block(Block::default().borders(Borders::ALL).title("Locals"));
    f.render_widget(locals, chunks[1]);
}

fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init();

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: simple-tui <trace-dir> [dap-server-path]");
        std::process::exit(1);
    }
    let dap_bin = if args.len() > 2 {
        Some(args[2].as_str())
    } else {
        None
    };
    let program = if args.len() > 3 {
        args[3].clone()
    } else {
        "".to_string()
    };
    let mut app = App::new(&args[1], dap_bin, &program)?;

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
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    Ok(())
}
