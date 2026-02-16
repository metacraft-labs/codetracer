using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using UiTests.Execution;

namespace UiTests.Configuration;

/// <summary>
/// Strongly-typed view over the configuration consumed by the UI test harness.
/// </summary>
public sealed class AppSettings
{
    /// <summary>
    /// Runner-wide options controlling scheduling, filtering, and diagnostics.
    /// </summary>
    [Required]
    public RunnerSettings Runner { get; set; } = new();

    /// <summary>
    /// Parameters controlling Electron sessions.
    /// </summary>
    [Required]
    public ElectronSettings Electron { get; set; } = new();

    /// <summary>
    /// Parameters controlling CodeTracer web-hosted sessions.
    /// </summary>
    [Required]
    public WebSettings Web { get; set; } = new();

    /// <summary>
    /// Declarative catalogue describing which scenarios to execute.
    /// </summary>
    public IReadOnlyList<ScenarioSettings> Scenarios { get; set; } = Array.Empty<ScenarioSettings>();

    /// <summary>
    /// Named test suites referencing sets of registered test identifiers.
    /// </summary>
    public Dictionary<string, SuiteDefinition> Suites { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Named runner profiles describing reusable scheduling presets.
    /// </summary>
    public Dictionary<string, RunnerProfileSettings> Profiles { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class RunnerSettings
{
    /// <summary>
    /// Explicit max parallel test instances; null => detect via <see cref="IParallelismProvider"/>.
    /// </summary>
    [Range(1, 512)]
    public int? MaxParallelInstances { get; set; }
        = null;

    /// <summary>
    /// Optional list of test identifiers to run (case-insensitive). Empty => run all registered tests.
    /// </summary>
    public IReadOnlyList<string> IncludeTests { get; set; } = Array.Empty<string>();

    /// <summary>
    /// Optional list of test identifiers to skip.
    /// </summary>
    public IReadOnlyList<string> ExcludeTests { get; set; } = Array.Empty<string>();

    /// <summary>
    /// When true, the runner aborts at the first failure instead of collecting all errors.
    /// </summary>
    public bool StopOnFirstFailure { get; set; }
        = false;

    /// <summary>
    /// Maximum number of retry attempts for failed tests. 0 means no retries.
    /// </summary>
    [Range(0, 10)]
    public int MaxRetries { get; set; } = 0;

    /// <summary>
    /// Default execution mode used when scenarios omit an explicit target.
    /// </summary>
    [EnumDataType(typeof(TestMode))]
    public TestMode DefaultMode { get; set; } = TestMode.Electron;

    /// <summary>
    /// Ordered list of modes to execute for each scenario. Defaults to running both Electron and Web targets.
    /// </summary>
    public IReadOnlyList<TestMode> ExecutionModes { get; set; } = new[] { TestMode.Electron, TestMode.Web };

    /// <summary>
    /// Pseudo-setting illustrating how scheduler plug-ins could be configured.
    /// Accepts values like "Semaphore", "WorkStealing", or "Custom:{FullyQualifiedType}".
    /// </summary>
    [RegularExpression(@"^(Semaphore|WorkStealing|Custom:.*)$", ErrorMessage = "Scheduler must be 'Semaphore', 'WorkStealing', or 'Custom:<type>'.")]
    public string Scheduler { get; set; } = "Semaphore";

    /// <summary>
    /// When non-null, emits execution summaries to the specified directory (pseudo-setting example).
    /// </summary>
    [FileExtensions(Extensions = "json,ndjson,txt")]
    public string? DiagnosticsOutput { get; set; }
        = null;

    /// <summary>
    /// Enables verbose console logging for the entire run (test lifecycle, process counts, etc.).
    /// </summary>
    public bool VerboseConsole { get; set; }
        = false;

    /// <summary>
    /// When true, enables Playwright trace recording for each test execution.
    /// Traces are saved to the diagnostics output directory as {test}_{scenario}.trace.zip
    /// and can be viewed at https://trace.playwright.dev/ or with 'npx playwright show-trace'.
    /// </summary>
    public bool PlaywrightTrace { get; set; }
        = false;

    /// <summary>
    /// Optional grace periods and overrides for slow-loading UI components.
    /// </summary>
    [Required]
    public ComponentLoadSettings ComponentLoad { get; set; } = new();
}

public sealed class ComponentLoadSettings
{
    /// <summary>
    /// Extra delay (in milliseconds) to allow the event log to populate after its tab appears.
    /// </summary>
    [Range(0, 120_000)]
    public int EventLogGracePeriodMs { get; set; }
        = 10_000;
}

public sealed class ScenarioSettings
{
    /// <summary>
    /// Stable identifier describing the scenario; used for filtering and reporting.
    /// </summary>
    [Required]
    public string Id { get; set; } = string.Empty;

    /// <summary>
    /// Optional human-readable description.
    /// </summary>
    public string? Description { get; set; }
        = null;

    /// <summary>
    /// Target runtime (Electron or Web).
    /// </summary>
    [EnumDataType(typeof(TestMode))]
    public TestMode Mode { get; set; } = TestMode.Electron;

    /// <summary>
    /// Logical test suite to invoke (e.g. "NoirSpaceShip").
    /// </summary>
    [Required]
    public string Test { get; set; } = string.Empty;

    /// <summary>
    /// Indicates whether the scenario should be executed.
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Index into the event log to select before executing assertions (1-based).
    /// </summary>
    [Range(1, 500)]
    public int EventIndex { get; set; } = 1;

    /// <summary>
    /// Delay (in seconds) to wait before activating the event. Defaults to 0.
    /// </summary>
    [Range(0, 300)]
    public double DelaySeconds { get; set; } = 0;

    /// <summary>
    /// Optional tags for grouping or selective execution (pseudo-setting example).
    /// </summary>
    public IReadOnlyList<string> Tags { get; set; } = Array.Empty<string>();

    /// <summary>
    /// Whether to collect extended telemetry for the scenario (pseudo-setting example).
    /// </summary>
    public bool CollectTelemetry { get; set; }
        = false;

    /// <summary>
    /// Enables detailed debug logging (RetryHelpers, pane interactions, etc.) for this scenario.
    /// </summary>
    public bool VerboseLogging { get; set; }
        = false;

    /// <summary>
    /// Optional trace program path for this scenario. When non-null, overrides the test-level
    /// and global <see cref="ElectronSettings.TraceProgram"/> defaults.
    /// </summary>
    public string? TraceProgram { get; set; } = null;
}

public sealed class ElectronSettings
{
    /// <summary>
    /// Relative path to the trace package to record before launching the Electron app.
    /// </summary>
    [Required]
    public string TraceProgram { get; set; } = "noir_space_ship";

    /// <summary>
    /// Time (in seconds) allowed for the CDP endpoint to become available.
    /// </summary>
    [Range(1, 120)]
    public int CdpStartupTimeoutSeconds { get; set; } = 20;

    /// <summary>
    /// Allows overriding the default shared memory directory for Electron (pseudo-setting example).
    /// </summary>
    public string? SharedMemoryDirectory { get; set; }
        = null;

    /// <summary>
    /// Optional EDID preference when positioning Electron windows.
    /// </summary>
    public string? PreferredDisplayEdid { get; set; }
        = null;

    /// <summary>
    /// Optional display index (1-based) when selecting a monitor for Electron windows.
    /// </summary>
    [Range(1, 16)]
    public int? PreferredDisplayIndex { get; set; }
        = null;
}

public sealed class WebSettings
{
    /// <summary>
    /// Default path to a CodeTracer trace when CODETRACER_TRACE_PATH is not set.
    /// </summary>
    public string? DefaultTraceDirectory { get; set; }

    /// <summary>
    /// Time (in seconds) allowed for ct host to accept connections.
    /// </summary>
    [Range(1, 120)]
    public int HostStartupTimeoutSeconds { get; set; } = 30;

    /// <summary>
    /// Options controlling Playwright browser position and viewport.
    /// </summary>
    [Required]
    public BrowserWindowSettings BrowserWindow { get; set; } = new();

    /// <summary>
    /// Configures port allocation strategy (pseudo-setting example).
    /// </summary>
    [Required]
    public HostPortSettings Ports { get; set; } = new();
}

public sealed class BrowserWindowSettings
{
    /// <summary>
    /// When true, launches the browser in headless mode.
    /// </summary>
    public bool Headless { get; set; } = false;

    /// <summary>
    /// Optional window size override (e.g. "1920x1080"). Pseudo-setting example; not yet consumed.
    /// </summary>
    [RegularExpression(@"^\d+x\d+$", ErrorMessage = "WindowSize must be formatted as <width>x<height>.")]
    public string? WindowSize { get; set; }
        = null;

    /// <summary>
    /// Optional display identifier when multiple monitors are available (1-based index).
    /// </summary>
    [Range(1, 16)]
    public int? PreferredDisplayIndex { get; set; }
        = null;

    /// <summary>
    /// Optional EDID preference when selecting a monitor.
    /// </summary>
    public string? PreferredDisplayEdid { get; set; }
        = null;
}

public sealed class HostPortSettings
{
    /// <summary>
    /// Strategy for selecting TCP ports (e.g. "Random", "Fixed", or "Sequence").
    /// </summary>
    [RegularExpression(@"^(Random|Fixed|Sequence)$", ErrorMessage = "PortStrategy must be 'Random', 'Fixed', or 'Sequence'.")]
    public string PortStrategy { get; set; } = "Random";

    /// <summary>
    /// When using the "Fixed" port strategy, this value is required.
    /// </summary>
    [Range(1024, 65535)]
    public int? FixedPort { get; set; }
        = null;

    /// <summary>
    /// Optional list of preferred ports to try before falling back to random allocation (pseudo-setting example).
    /// </summary>
    public IReadOnlyList<int> PreferredPorts { get; set; } = Array.Empty<int>();
}

public sealed class SuiteDefinition
{
    /// <summary>
    /// Tests included in the suite.
    /// </summary>
    [Required]
    public IReadOnlyList<string> Tests { get; set; } = Array.Empty<string>();

    /// <summary>
    /// Optional tags for documentation or filtering purposes.
    /// </summary>
    public IReadOnlyList<string> Tags { get; set; } = Array.Empty<string>();
}

public sealed class RunnerProfileSettings
{
    /// <summary>
    /// Overrides the runner parallelism (null => fall back to the recommended value).
    /// </summary>
    [Range(1, 512)]
    public int? MaxParallelInstances { get; set; }
        = null;

    /// <summary>
    /// Overrides the stop-on-first-failure setting.
    /// </summary>
    public bool? StopOnFirstFailure { get; set; }
        = null;

    /// <summary>
    /// Overrides execution modes when provided.
    /// </summary>
    public IReadOnlyList<TestMode>? ExecutionModes { get; set; }
        = null;

    /// <summary>
    /// Overrides the default mode for scenarios.
    /// </summary>
    public TestMode? DefaultMode { get; set; }
        = null;
}
