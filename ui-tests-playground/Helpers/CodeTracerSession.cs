using System.Diagnostics;
using Microsoft.Playwright;

namespace UiTestsPlayground.Helpers;

internal sealed class CodeTracerSession : IAsyncDisposable
{
    private readonly Process _process;
    private readonly IPlaywright _playwright;
    private bool _disposed;

    public IBrowser Browser { get; }

    public CodeTracerSession(Process process, IBrowser browser, IPlaywright playwright)
    {
        _process = process;
        Browser = browser;
        _playwright = playwright;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        try
        {
            await Browser.CloseAsync();
        }
        catch
        {
            // ignore close failures
        }

        try
        {
            await Browser.DisposeAsync();
        }
        catch
        {
            // ignore dispose failures
        }

        try
        {
            _playwright.Dispose();
        }
        catch
        {
            // ignore dispose failures
        }

        try
        {
            if (_process.HasExited)
            {
                return;
            }

            if (!_process.WaitForExit(5000))
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(5000);
            }
        }
        catch
        {
            // ignore kill failures
        }
        finally
        {
            _process.Dispose();
        }
    }
}
