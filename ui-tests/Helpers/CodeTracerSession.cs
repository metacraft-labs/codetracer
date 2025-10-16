using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Helpers;

/// <summary>
/// Represents an active CodeTracer UI test session and guarantees
/// the underlying Electron process is cleaned up when disposed.
/// </summary>
public sealed class CodeTracerSession : IAsyncDisposable
{
    private readonly Process _process;
    private readonly IPlaywright _playwright;
    private bool _disposed;

    public IBrowser Browser { get; }

    internal CodeTracerSession(Process process, IBrowser browser, IPlaywright playwright)
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
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to close browser cleanly: {ex}");
        }
        finally
        {
            try
            {
                await Browser.DisposeAsync();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to dispose browser: {ex}");
            }
        }

        try
        {
            _playwright.Dispose();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to dispose Playwright: {ex}");
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
                if (!_process.WaitForExit(5000))
                {
                    Console.Error.WriteLine("ct process did not exit within timeout after Kill.");
                }
            }
        }
        catch (InvalidOperationException)
        {
            // Process already exited.
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to terminate ct process: {ex}");
        }
        finally
        {
            _process.Dispose();
        }
    }
}
