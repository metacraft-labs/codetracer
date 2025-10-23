using UiTests.Configuration;

namespace UiTests.Execution;

public sealed record UiTestDescriptor(
    string Id,
    string DisplayName,
    UiTestDelegate Handler,
    IReadOnlyList<string> Tags)
{
    public UiTestDescriptor(string id, string displayName, UiTestDelegate handler)
        : this(id, displayName, handler, Array.Empty<string>())
    {
    }
}

public delegate Task UiTestDelegate(TestExecutionContext context);

public sealed record TestExecutionContext(
    ScenarioSettings Scenario,
    TestMode Mode,
    Microsoft.Playwright.IPage Page,
    CancellationToken CancellationToken);
