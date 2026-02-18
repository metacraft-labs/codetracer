using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using UiTests.Configuration;

namespace UiTests.Infrastructure;

internal interface ICodetracerLauncher
{
    string CtPath { get; }
    string CtInstallDirectory { get; }
    bool IsCtAvailable { get; }
    Task<int> RecordProgramAsync(string relativePath, CancellationToken cancellationToken);
    string ResolveTracePath(string? overridePath);
}

internal sealed class CodetracerLauncher : ICodetracerLauncher
{
    private readonly ILogger<CodetracerLauncher> _logger;
    private readonly AppSettings _settings;

    private static readonly string RepoRoot =
        Environment.GetEnvironmentVariable("CODETRACER_REPO_ROOT_PATH") ??
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));

    private static readonly string ProgramsDirectory = Path.Combine(RepoRoot, "test-programs");

    private static readonly string LegacyDefaultTraceDirectory =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "share", "codetracer");

    public CodetracerLauncher(IOptions<AppSettings> settings, ILogger<CodetracerLauncher> logger)
    {
        _settings = settings.Value;
        _logger = logger;

        var configuredCtPath = Environment.GetEnvironmentVariable("CODETRACER_E2E_CT_PATH") ??
            Path.Combine(
                Environment.GetEnvironmentVariable("NIX_CODETRACER_EXE_DIR") ??
                Path.Combine(RepoRoot, "src", "build-debug"),
                "bin", "ct");

        CtPath = Path.GetFullPath(configuredCtPath);
        CtInstallDirectory = Path.GetDirectoryName(CtPath) ?? RepoRoot;
    }

    public string CtPath { get; }

    public string CtInstallDirectory { get; }

    public bool IsCtAvailable => File.Exists(CtPath);

    public async Task<int> RecordProgramAsync(string relativePath, CancellationToken cancellationToken)
    {
        if (!IsCtAvailable)
        {
            throw new FileNotFoundException($"ct executable not found at {CtPath}", CtPath);
        }

        var programPath = Path.Combine(ProgramsDirectory, relativePath);
        var programExists = File.Exists(programPath) || Directory.Exists(programPath);
        if (!programExists)
        {
            throw new FileNotFoundException($"Program not found: {programPath}", programPath);
        }

        var psi = new ProcessStartInfo(CtPath)
        {
            WorkingDirectory = CtInstallDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        psi.ArgumentList.Add("record");
        psi.ArgumentList.Add(programPath);

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start ct record process.");

        // Read stdout/stderr concurrently while the process runs to avoid pipe-buffer
        // deadlocks.  ct record merges stderr into stdout (Nim's poStdErrToStdOut), so
        // the real error messages appear on stdout, not stderr.
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);

        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        if (process.ExitCode != 0)
        {
            // Include both streams — ct merges stderr→stdout, so stderr is typically
            // empty while the actual diagnostics are in stdout.
            var combined = string.IsNullOrWhiteSpace(stderr) ? stdout : $"{stderr}\n{stdout}";
            throw new InvalidOperationException(
                $"ct record failed with exit code {process.ExitCode} (binary: {CtPath}):\n{combined}");
        }

        var traceId = ParseTraceId(stdout);
        var logLevel = _settings.Runner.VerboseConsole ? LogLevel.Information : LogLevel.Debug;
        _logger.Log(logLevel, "Recorded trace {TraceId} for program {Program}.", traceId, relativePath);
        return traceId;
    }

    public string ResolveTracePath(string? overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            return overridePath;
        }

        var defaultTraceDirectory = string.IsNullOrWhiteSpace(_settings.Web.DefaultTraceDirectory)
            ? LegacyDefaultTraceDirectory
            : Path.GetFullPath(_settings.Web.DefaultTraceDirectory);

        if (!Directory.Exists(defaultTraceDirectory))
        {
            throw new DirectoryNotFoundException($"Default trace directory not found: {defaultTraceDirectory}. Set CODETRACER_TRACE_PATH to a valid trace.");
        }

        var traces = Directory.GetDirectories(defaultTraceDirectory, "trace-*", SearchOption.TopDirectoryOnly)
            .Select(path => (Path: path, Number: ParseTraceNumber(Path.GetFileName(path))))
            .Where(item => item.Number.HasValue)
            .Select(item => (item.Path, item.Number!.Value))
            .OrderByDescending(item => item.Value)
            .ToList();

        if (traces.Count == 0)
        {
            throw new InvalidOperationException($"No trace directories found under {defaultTraceDirectory}. Record a trace or set CODETRACER_TRACE_PATH.");
        }

        return traces.First().Path;
    }

    private static int ParseTraceId(string output)
    {
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var lastLine = lines.LastOrDefault();
        if (lastLine is null)
        {
            throw new InvalidOperationException("ct record did not produce any output.");
        }

        var parts = lastLine.Split(':', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length < 2 || !int.TryParse(parts[1], out var id))
        {
            throw new InvalidOperationException($"Unable to parse trace id from ct output: {lastLine}");
        }

        return id;
    }

    private static int? ParseTraceNumber(string? directoryName)
    {
        if (string.IsNullOrEmpty(directoryName))
        {
            return null;
        }

        var suffix = directoryName.Replace("trace-", string.Empty, StringComparison.OrdinalIgnoreCase);
        return int.TryParse(suffix, out var value) ? value : (int?)null;
    }
}
