using UiTests.Configuration;

namespace UiTests.Execution;

public sealed record UiTestDescriptor(
    string Id,
    string DisplayName,
    UiTestDelegate Handler,
    IReadOnlyList<string> Tags)
{
    /// <summary>
    /// Optional trace program path for this test. When null, falls back to the scenario-level
    /// or global default configured in <see cref="Configuration.ElectronSettings.TraceProgram"/>.
    /// </summary>
    public string? TraceProgram { get; init; } = null;

    /// <summary>
    /// Creates a test descriptor with no tags and no per-test trace program override.
    /// </summary>
    public UiTestDescriptor(string id, string displayName, UiTestDelegate handler)
        : this(id, displayName, handler, Array.Empty<string>())
    {
    }

    /// <summary>
    /// Creates a test descriptor with a per-test trace program override and no tags.
    /// Pass null for <paramref name="traceProgram"/> to fall back to the scenario or global default.
    /// </summary>
    public UiTestDescriptor(string id, string displayName, UiTestDelegate handler, string? traceProgram)
        : this(id, displayName, handler, Array.Empty<string>())
    {
        TraceProgram = traceProgram;
    }
}

public delegate Task UiTestDelegate(TestExecutionContext context);

public sealed record TestExecutionContext(
    ScenarioSettings Scenario,
    TestMode Mode,
    Microsoft.Playwright.IPage Page,
    CancellationToken CancellationToken);
