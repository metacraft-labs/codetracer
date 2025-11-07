using System.Collections.Generic;
using UiTests.Execution;

namespace UiTests.Configuration;

internal sealed class SuiteProfileSelection
{
    public SuiteProfileSelection(
        string? suite,
        string? profile,
        IReadOnlyList<string> includeOverrides,
        IReadOnlyList<string> excludeOverrides,
        IReadOnlyList<TestMode> modeOverrides)
    {
        Suite = Normalize(suite);
        Profile = Normalize(profile);
        IncludeOverrides = includeOverrides ?? Array.Empty<string>();
        ExcludeOverrides = excludeOverrides ?? Array.Empty<string>();
        ModeOverrides = modeOverrides ?? Array.Empty<TestMode>();
    }

    public string? Suite { get; }

    public string? Profile { get; }

    public IReadOnlyList<string> IncludeOverrides { get; }

    public IReadOnlyList<string> ExcludeOverrides { get; }

    public IReadOnlyList<TestMode> ModeOverrides { get; }

    private static string? Normalize(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }
}
