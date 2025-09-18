using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Helpers;

/// <summary>
/// Represents a single CodeTracer session launched for the UI tests.
/// Keeps track of the root <see cref="Process"/> as well as the
/// Playwright resources attached to it so that callers can cleanly
/// dispose the session when finished.
/// </summary>
public sealed class CodeTracerSession : IAsyncDisposable
{
    private int _isTerminated;

    public CodeTracerSession(Process rootProcess, IBrowser browser, IPlaywright playwright)
    {
        RootProcess = rootProcess ?? throw new ArgumentNullException(nameof(rootProcess));
        Browser = browser ?? throw new ArgumentNullException(nameof(browser));
        Playwright = playwright ?? throw new ArgumentNullException(nameof(playwright));
    }

    /// <summary>
    /// Gets the CodeTracer root process launched for this session.
    /// </summary>
    public Process RootProcess { get; }

    /// <summary>
    /// Gets the connected Playwright browser instance.
    /// </summary>
    public IBrowser Browser { get; }

    /// <summary>
    /// Gets the Playwright runtime associated with the browser connection.
    /// </summary>
    internal IPlaywright Playwright { get; }

    /// <summary>
    /// Marks the session as terminated. Returns <c>true</c> only the first
    /// time it is invoked so that cleanup logic runs once.
    /// </summary>
    internal bool TryMarkTerminated() => Interlocked.Exchange(ref _isTerminated, 1) == 0;

    /// <summary>
    /// Terminates the session asynchronously.
    /// </summary>
    public ValueTask DisposeAsync() => CodeTracerSessionRegistry.TerminateSessionAsync(this);
}
