using System.ComponentModel.DataAnnotations;

namespace UiTests.Configuration;

/// <summary>
/// Configuration surface controlling stability test execution, logging, and artifacts.
/// </summary>
public sealed class StabilitySettings
{
    /// <summary>
    /// Artifact and logging settings that apply to all stability runs.
    /// </summary>
    [Required]
    public StabilityArtifactSettings Artifacts { get; set; } = new();

    /// <summary>
    /// Runtime defaults for stability scenarios (durations, seeds, overrides).
    /// </summary>
    [Required]
    public StabilityRuntimeSettings Runtime { get; set; } = new();

    /// <summary>
    /// Default deterministic seed used when a scenario does not provide one explicitly.
    /// </summary>
    public int DefaultSeed { get; set; } = 299792458;

    /// <summary>
    /// Program-specific overrides (path, default durations/iteration limits).
    /// </summary>
    public IReadOnlyList<StabilityProgramSettings> Programs { get; set; } = Array.Empty<StabilityProgramSettings>();
}

public sealed class StabilityArtifactSettings
{
    /// <summary>
    /// Root directory (relative to repository) for stability artifacts (logs, summaries, media).
    /// </summary>
    [Required]
    public string Root { get; set; } = "artifacts";

    /// <summary>
    /// Controls video recording behaviour for stability runs.
    /// </summary>
    public StabilityRecordingMode VideoMode { get; set; } = StabilityRecordingMode.On;

    /// <summary>
    /// Controls screenshot capture behaviour for stability runs.
    /// </summary>
    public StabilityRecordingMode ScreenshotMode { get; set; } = StabilityRecordingMode.On;

    /// <summary>
    /// When true, clears existing log files under <see cref="Root"/> before the run.
    /// </summary>
    public bool ClearLogs { get; set; }
        = false;

    /// <summary>
    /// When true, clears existing media artifacts (videos/screenshots) under <see cref="Root"/> before the run.
    /// </summary>
    public bool ClearArtifacts { get; set; }
        = false;
}

public enum StabilityRecordingMode
{
    Off = 0,
    On = 1,
    FailOnly = 2
}

public sealed class StabilityRuntimeSettings
{
    /// <summary>
    /// Default time-bound duration in minutes applied when a scenario does not override it.
    /// </summary>
    [Range(1, 1440)]
    public int DefaultDurationMinutes { get; set; } = 30;

    /// <summary>
    /// Optional max-runtime ceiling in minutes; defaults to <see cref="DefaultDurationMinutes"/>.
    /// </summary>
    [Range(1, 1440)]
    public int DefaultMaxRuntimeMinutes { get; set; } = 30;

    /// <summary>
    /// Duration in minutes used when "overnight" runs are requested (e.g., 8 hours).
    /// </summary>
    [Range(1, 1440)]
    public int OvernightDurationMinutes { get; set; } = 480;

    /// <summary>
    /// Override duration in minutes supplied via CLI; null means use defaults.
    /// </summary>
    [Range(1, 1440)]
    public int? OverrideDurationMinutes { get; set; }
        = null;

    /// <summary>
    /// Override max runtime in minutes supplied via CLI; null means use defaults.
    /// </summary>
    [Range(1, 1440)]
    public int? OverrideMaxRuntimeMinutes { get; set; }
        = null;

    /// <summary>
    /// When true, uses the overnight duration instead of <see cref="DefaultDurationMinutes"/>.
    /// </summary>
    public bool Overnight { get; set; }
        = false;
}

public sealed class StabilityProgramSettings
{
    /// <summary>
    /// Program identifier (e.g., noir_space_ship).
    /// </summary>
    [Required]
    public string Id { get; set; } = string.Empty;

    /// <summary>
    /// Relative path to the program file or folder.
    /// </summary>
    [Required]
    public string ProgramPath { get; set; } = string.Empty;

    /// <summary>
    /// Optional duration override in minutes for this program.
    /// </summary>
    [Range(1, 1440)]
    public int? DurationMinutes { get; set; }
        = null;

    /// <summary>
    /// Optional iteration cap for stability loops on this program.
    /// </summary>
    [Range(1, int.MaxValue)]
    public int? IterationLimit { get; set; }
        = null;
}
