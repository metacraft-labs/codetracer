using System.Diagnostics;
using Microsoft.Playwright;
using UiTests.Infrastructure;

namespace UiTests.Helpers;

public sealed class WebTestSession : IAsyncDisposable
{
    private readonly Process _hostProcess;
    private readonly IProcessLifecycleManager? _processLifecycle;
    private bool _disposed;

    internal WebTestSession(Process hostProcess, IPlaywright playwright, IBrowser browser, IBrowserContext context, IPage page, IProcessLifecycleManager? processLifecycle = null, string? processLabel = null)
    {
        _hostProcess = hostProcess;
        _processLifecycle = processLifecycle;
        Playwright = playwright;
        Browser = browser;
        Context = context;
        Page = page;
        _processLifecycle?.RegisterProcess(_hostProcess, processLabel ?? $"ct-host:{hostProcess.Id}");
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
            _processLifecycle?.UnregisterProcess(_hostProcess.Id);
            _hostProcess.Dispose();
        }
    }
}
