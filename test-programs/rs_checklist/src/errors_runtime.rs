use crate::ChecklistResult;
use std::error::Error;
use std::fmt;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug)]
enum ChecklistError {
    Missing,
    Parse(std::num::ParseIntError),
    Io(io::Error),
}

impl fmt::Display for ChecklistError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing => write!(f, "missing value"),
            Self::Parse(e) => write!(f, "parse failure: {e}"),
            Self::Io(e) => write!(f, "io failure: {e}"),
        }
    }
}

impl Error for ChecklistError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Parse(e) => Some(e),
            Self::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::num::ParseIntError> for ChecklistError {
    fn from(value: std::num::ParseIntError) -> Self {
        Self::Parse(value)
    }
}

impl From<io::Error> for ChecklistError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

pub fn run() -> ChecklistResult {
    fallible_operations()?;
    file_io_demo()?;
    time_and_sleep();
    panic_and_unwind();
    Ok(())
}

fn fallible_operations() -> Result<(), ChecklistError> {
    fn parse_pair(input: &str) -> Result<(i32, i32), ChecklistError> {
        let (left, right) = input.split_once(',').ok_or(ChecklistError::Missing)?;
        let a: i32 = left.trim().parse()?;
        let b: i32 = right.trim().parse()?;
        Ok((a, b))
    }

    fn divide(numerator: i32, denominator: i32) -> Result<i32, ChecklistError> {
        if denominator == 0 {
            return Err(ChecklistError::Missing);
        }
        Ok(numerator / denominator)
    }

    let parsed = parse_pair("10, 2")?;
    let quotient = divide(parsed.0, parsed.1)?;
    println!("[er-01] quotient {}", quotient);

    let option_value: Option<i32> = None;
    let number = option_value.ok_or(ChecklistError::Missing).unwrap_or(-1);
    println!("[er-02] option -> result fallback {number}");
    Ok(())
}

fn file_io_demo() -> Result<(), ChecklistError> {
    let mut path = PathBuf::from(std::env::temp_dir());
    path.push("rs_checklist_demo.txt");

    {
        let mut file = fs::File::create(&path)?;
        writeln!(file, "line one")?;
        writeln!(file, "line two")?;
    }

    let file = fs::File::open(&path)?;
    let reader = BufReader::new(file);
    let mut lines = Vec::new();
    for line in reader.lines() {
        lines.push(line?);
    }
    println!("[er-03] read lines {:?}", lines);

    let missing = fs::File::open("does_not_exist.txt");
    match missing {
        Ok(_) => println!("[er-04] unexpectedly opened missing file"),
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            println!("[er-04] missing file handled: {e}")
        }
        Err(e) => println!("[er-04] other io error {e}"),
    }

    fs::remove_file(path)?;
    Ok(())
}

fn time_and_sleep() {
    let start = Instant::now();
    thread::sleep(Duration::from_millis(20));
    let elapsed = start.elapsed();
    println!("[er-05] elapsed {:?}", elapsed);
}

fn panic_and_unwind() {
    struct Guard(&'static str);
    impl Drop for Guard {
        fn drop(&mut self) {
            println!("[er-drop] dropping {}", self.0);
        }
    }

    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|info| {
        println!("[er-06] panic hook: {info}");
    }));

    let result = std::panic::catch_unwind(|| {
        let _guard = Guard("inside panic");
        panic!("forced panic");
    });
    println!("[er-07] catch_unwind result={result:?}");

    std::panic::set_hook(hook);
}
