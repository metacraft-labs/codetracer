using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Represents a single record in the call trace pane.
/// The current tests do not use these values but the structure
/// mirrors the previous Nim implementation.
/// </summary>
public class CallTraceRecord
{
    public CallTraceRecord(ILocator root) => Root = root;

    public ILocator Root { get; }
}
