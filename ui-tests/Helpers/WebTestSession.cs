using System.Diagnostics;
using Microsoft.Playwright;

namespace UiTests.Helpers;

public sealed class WebTestSession : IAsyncDisposable
{
    private readonly Process _hostProcess;
    private bool _disposed;

    public WebTestSession(Process hostProcess, IPlaywright playwright, IBrowser browser, IBrowserContext context, IPage page)
    {
        _hostProcess = hostProcess;
        Playwright = playwright;
        Browser = browser;
        Context = context;
        Page = page;
    }

    public IPlaywright Playwright { get; }
    public IBrowser Browser { get; }
    public IBrowserContext Context { get; }
    public IPage Page { get; }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        try
        {
            await Page.CloseAsync();
        }
        catch
        {
            // ignore cleanup failures
        }

        try
        {
            await Context.CloseAsync();
        }
        catch
        {
            // ignore cleanup failures
        }

        try
        {
            await Browser.CloseAsync();
        }
        catch
        {
            // ignore cleanup failures
        }

        try
        {
            await Browser.DisposeAsync();
        }
        catch
        {
            // ignore cleanup failures
        }

        try
        {
            await Context.DisposeAsync();
        }
        catch
        {
            // ignore cleanup failures
        }

        try
        {
            Playwright.Dispose();
        }
        catch
        {
            // ignore cleanup failures
        }

        try
        {
            if (!_hostProcess.HasExited)
            {
                _hostProcess.Kill(entireProcessTree: true);
                _hostProcess.WaitForExit(5000);
            }
        }
        catch
        {
            // ignore cleanup failures
        }
        finally
        {
            _hostProcess.Dispose();
        }
    }
}
