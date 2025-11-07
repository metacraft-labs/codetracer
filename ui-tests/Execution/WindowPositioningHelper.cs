using System.Collections.Generic;
using System.Diagnostics;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.Helpers;
using UiTests.Infrastructure;

namespace UiTests.Execution;

internal static class WindowPositioningHelper
{
    public static async Task<bool> MoveWindowAsync(IPage page, MonitorInfo? monitor)
    {
        if (monitor.HasValue)
        {
            return await page.EvaluateAsync<bool>(@"({ x, y, width, height }) => {
                try {
                    if (typeof window.moveTo === 'function') {
                        window.moveTo(x, y);
                    }
                    if (typeof window.resizeTo === 'function') {
                        window.resizeTo(width, height);
                    }
                    return true;
                } catch (error) {
                    console.warn('window move/resize failed', error);
                    return false;
                } finally {
                    window.dispatchEvent(new Event('resize'));
                }
            }", new
            {
                x = monitor.Value.X,
                y = monitor.Value.Y,
                width = monitor.Value.Width,
                height = monitor.Value.Height
            });
        }

        return await page.EvaluateAsync<bool>(@"() => {
            try {
                const targetWidth = window.screen && Number.isFinite(window.screen.availWidth)
                    ? window.screen.availWidth
                    : window.innerWidth;
                const targetHeight = window.screen && Number.isFinite(window.screen.availHeight)
                    ? window.screen.availHeight
                    : window.innerHeight;
                if (typeof window.moveTo === 'function') {
                    window.moveTo(0, 0);
                }
                if (typeof window.resizeTo === 'function') {
                    window.resizeTo(targetWidth, targetHeight);
                }
                return true;
            } catch (error) {
                console.warn('window move/resize failed', error);
                return false;
            } finally {
                window.dispatchEvent(new Event('resize'));
            }
        }");
    }

    public static async Task<bool> MoveElectronWindowAsync(CodeTracerSession session, IPage page, MonitorInfo? monitor)
    {
        if (!monitor.HasValue)
        {
            return false;
        }

        try
        {
            await using var pageSession = await page.Context.NewCDPSessionAsync(page);
            var targetInfoResult = await pageSession.SendAsync("Target.getTargetInfo");
            if (targetInfoResult is not JsonElement targetInfoElement ||
                !targetInfoElement.TryGetProperty("targetInfo", out var targetInfo) ||
                !targetInfo.TryGetProperty("targetId", out var targetIdProperty))
            {
                return false;
            }

            var targetId = targetIdProperty.GetString();
            if (string.IsNullOrEmpty(targetId))
            {
                return false;
            }

            await using var browserSession = await session.Browser.NewBrowserCDPSessionAsync();
            var windowInfoResult = await browserSession.SendAsync(
                "Browser.getWindowForTarget",
                new Dictionary<string, object>
                {
                    ["targetId"] = targetId
                });

            if (windowInfoResult is not JsonElement windowInfoElement ||
                !windowInfoElement.TryGetProperty("windowId", out var windowIdProperty))
            {
                return false;
            }

            var windowId = windowIdProperty.GetInt32();

            await browserSession.SendAsync(
                "Browser.setWindowBounds",
                new Dictionary<string, object>
                {
                    ["windowId"] = windowId,
                    ["bounds"] = new Dictionary<string, object>
                    {
                        ["left"] = monitor.Value.X,
                        ["top"] = monitor.Value.Y,
                        ["width"] = monitor.Value.Width,
                        ["height"] = monitor.Value.Height
                    }
                });

            return true;
        }
        catch
        {
            return TryMoveElectronWindowWithWmctrl(monitor.Value);
        }
    }

    private static bool TryMoveElectronWindowWithWmctrl(MonitorInfo monitor)
    {
        try
        {
            var psi = new ProcessStartInfo("wmctrl")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            psi.ArgumentList.Add("-r");
            psi.ArgumentList.Add("CodeTracer");
            psi.ArgumentList.Add("-e");
            psi.ArgumentList.Add($"0,{monitor.X},{monitor.Y},{monitor.Width},{monitor.Height}");

            using var process = Process.Start(psi);
            if (process is null)
            {
                return false;
            }

            if (!process.WaitForExit(1500))
            {
                process.Kill(entireProcessTree: true);
                return false;
            }

            return process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }
}
