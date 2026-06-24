use clap::{Parser, Subcommand};
use codetracer_bench::gui_ops::{self, Backend, DapMeasurementDriver, Operation, Platform};
use codetracer_bench::{Language, write_report};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "ct-bench")]
#[command(about = "CodeTracer product benchmark drivers")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    OmniscientDbSize {
        #[arg(long)]
        languages: Option<String>,
        #[arg(long)]
        all_languages: bool,
        #[arg(long)]
        fixtures_root: Option<PathBuf>,
        #[arg(long)]
        temp_root: Option<PathBuf>,
    },
    SlicePrepSpeed {
        #[arg(long, default_value = "c_plus_plus")]
        language: String,
        #[arg(long, default_value = "1,2,4,8,16")]
        slice_counts: String,
        #[arg(long, default_value = "1,2,4,8")]
        prep_concurrency: String,
        #[arg(long)]
        program: Option<PathBuf>,
        #[arg(long)]
        fixtures_root: Option<PathBuf>,
        #[arg(long)]
        temp_root: Option<PathBuf>,
    },
    GuiOps {
        #[arg(long)]
        languages: Option<String>,
        #[arg(long)]
        backends: Option<String>,
        #[arg(long)]
        operations: Option<String>,
        #[arg(long, default_value_t = 10)]
        iterations: usize,
        #[arg(long)]
        fixtures_root: Option<PathBuf>,
        #[arg(long)]
        temp_root: Option<PathBuf>,
    },
    NativeOmniscientTiming {
        #[arg(long)]
        program: Option<PathBuf>,
        #[arg(long, default_value = "mcr,rr")]
        backends: String,
        #[arg(long, default_value_t = 1)]
        runs: usize,
        #[arg(long)]
        fixtures_root: Option<PathBuf>,
        #[arg(long)]
        temp_root: Option<PathBuf>,
    },
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    match cli.command {
        Command::OmniscientDbSize {
            languages,
            all_languages,
            fixtures_root,
            temp_root,
        } => {
            let fixtures_root = fixtures_root.unwrap_or_else(default_fixtures_root);
            let temp_root = temp_root.unwrap_or_else(|| default_temp_root("omniscient-db-size"));
            std::fs::create_dir_all(&temp_root)?;
            let languages = if all_languages {
                Language::all()
            } else {
                parse_languages(languages.as_deref())?.unwrap_or_else(Language::default_set)
            };
            let outcome =
                codetracer_bench::omniscient_db_size::run(&fixtures_root, &languages, &temp_root);
            for (language, reason) in &outcome.skipped {
                eprintln!("SKIPPED {}: {}", language.wire(), reason);
            }
            let dir = write_report(&outcome.report)?;
            println!("{}", dir.display());
        }
        Command::SlicePrepSpeed {
            language,
            slice_counts,
            prep_concurrency,
            program,
            fixtures_root,
            temp_root,
        } => {
            let language = Language::parse(&language)
                .ok_or_else(|| format!("unknown language for --language: {language}"))?;
            let fixtures_root = fixtures_root.unwrap_or_else(default_fixtures_root);
            let program = program.unwrap_or_else(|| {
                fixtures_root
                    .join("omniscient-db-size")
                    .join(language.wire())
                    .join("mid_length_compute")
                    .join(format!("main.{}", main_extension(language)))
            });
            let slice_counts = parse_usize_list(&slice_counts, "--slice-counts")?;
            let prep_concurrency = parse_usize_list(&prep_concurrency, "--prep-concurrency")?;
            let temp_root = temp_root.unwrap_or_else(|| default_temp_root("slice-prep-speed"));
            std::fs::create_dir_all(&temp_root)?;
            let outcome = codetracer_bench::slice_prep_speed::run(
                language,
                &program,
                &slice_counts,
                &prep_concurrency,
                &temp_root,
            );
            if let Some(reason) = &outcome.skip_reason {
                eprintln!("SKIPPED: {reason}");
            }
            let dir = write_report(&outcome.report)?;
            println!("{}", dir.display());
        }
        Command::GuiOps {
            languages,
            backends,
            operations,
            iterations,
            fixtures_root,
            temp_root,
        } => {
            let fixtures_root = fixtures_root.unwrap_or_else(default_fixtures_root);
            let temp_root = temp_root.unwrap_or_else(|| default_temp_root("gui-ops"));
            std::fs::create_dir_all(&temp_root)?;
            let languages =
                parse_languages(languages.as_deref())?.unwrap_or_else(gui_ops::default_languages);
            let backends =
                parse_backends(backends.as_deref())?.unwrap_or_else(gui_ops::default_backends);
            let operations =
                parse_operations(operations.as_deref())?.unwrap_or_else(Operation::all);
            let driver = DapMeasurementDriver::new(fixtures_root, iterations)
                .with_recording_root(temp_root.join("recordings"));
            let matrix = gui_ops::build_matrix(
                &driver,
                &backends,
                &[Platform::Linux, Platform::MacOs, Platform::Windows],
                &languages,
                &operations,
            );
            let dir = write_report(&matrix.to_report())?;
            println!("{}", dir.display());
        }
        Command::NativeOmniscientTiming {
            program,
            backends,
            runs,
            fixtures_root,
            temp_root,
        } => {
            let fixtures_root = fixtures_root.unwrap_or_else(default_fixtures_root);
            let program = program.unwrap_or_else(|| {
                codetracer_bench::native_omniscient_timing::default_program(&fixtures_root)
            });
            let backends = backends
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>();
            let temp_root =
                temp_root.unwrap_or_else(|| default_temp_root("native-omniscient-timing"));
            std::fs::create_dir_all(&temp_root)?;
            let outcome = codetracer_bench::native_omniscient_timing::run(
                &program, &backends, runs, &temp_root,
            );
            for reason in &outcome.skipped {
                eprintln!("SKIPPED: {reason}");
            }
            let dir = write_report(&outcome.report)?;
            println!("{}", dir.display());
        }
    }
    Ok(())
}

fn default_fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn default_temp_root(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("ct-bench-{name}-{}", std::process::id()))
}

fn parse_languages(
    value: Option<&str>,
) -> Result<Option<Vec<Language>>, Box<dyn std::error::Error>> {
    parse_optional_list(value, "language", Language::parse)
}

fn parse_backends(value: Option<&str>) -> Result<Option<Vec<Backend>>, Box<dyn std::error::Error>> {
    parse_optional_list(value, "backend", Backend::parse)
}

fn parse_operations(
    value: Option<&str>,
) -> Result<Option<Vec<Operation>>, Box<dyn std::error::Error>> {
    parse_optional_list(value, "operation", Operation::parse)
}

fn parse_optional_list<T, F>(
    value: Option<&str>,
    label: &str,
    mut parse: F,
) -> Result<Option<Vec<T>>, Box<dyn std::error::Error>>
where
    F: FnMut(&str) -> Option<T>,
{
    let Some(value) = value else {
        return Ok(None);
    };
    let mut out = Vec::new();
    for item in value.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        out.push(parse(item).ok_or_else(|| format!("unknown {label}: {item}"))?);
    }
    Ok(Some(out))
}

fn parse_usize_list(value: &str, flag: &str) -> Result<Vec<usize>, Box<dyn std::error::Error>> {
    let mut out = Vec::new();
    for item in value.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        out.push(
            item.parse::<usize>()
                .map_err(|e| format!("invalid {flag} value {item}: {e}"))?,
        );
    }
    if out.is_empty() {
        return Err(format!("{flag} must contain at least one value").into());
    }
    Ok(out)
}

fn main_extension(language: Language) -> &'static str {
    match language {
        Language::Python => "py",
        Language::CPlusPlus => "cpp",
        Language::Ruby => "rb",
        Language::JavaScript => "js",
        Language::C => "c",
        Language::Rust => "rs",
        Language::Nim => "nim",
        Language::Go => "go",
        Language::Cairo => "cairo",
        Language::Solana => "rs",
    }
}
