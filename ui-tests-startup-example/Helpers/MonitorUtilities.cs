using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;

namespace UiTestsPlayground.Helpers;

/// <summary>
/// Utilities for discovering monitor layouts and translating them into Playwright launch arguments.
/// </summary>
internal static class MonitorUtilities
{
    internal readonly record struct MonitorInfo(string Name, int Width, int Height, int X, int Y, bool IsPrimary);

    /// <summary>
    /// Retrieves connected monitor metadata via <c>xrandr --query</c>. Returns an empty collection when
    /// the command is unavailable or fails.
    /// </summary>
    public static IReadOnlyList<MonitorInfo> DetectMonitors()
    {
        try
        {
            var psi = new ProcessStartInfo("bash")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            psi.ArgumentList.Add("-lc");
            psi.ArgumentList.Add("xrandr --query");

            using var process = Process.Start(psi);
            if (process is null)
            {
                return Array.Empty<MonitorInfo>();
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(2000);

            var monitors = new List<MonitorInfo>();
            foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                if (!line.Contains(" connected", StringComparison.Ordinal))
                {
                    continue;
                }

                var parts = line.Split(" connected", 2, StringSplitOptions.TrimEntries);
                if (parts.Length < 2)
                {
                    continue;
                }

                var name = parts[0].Trim();
                var details = parts[1];
                var isPrimary = details.Contains("primary", StringComparison.OrdinalIgnoreCase);

                var match = Regex.Match(details, @"(?<width>\d+)x(?<height>\d+)\+(?<x>-?\d+)\+(?<y>-?\d+)");
                if (!match.Success)
                {
                    continue;
                }

                var width = int.Parse(match.Groups["width"].Value, CultureInfo.InvariantCulture);
                var height = int.Parse(match.Groups["height"].Value, CultureInfo.InvariantCulture);
                var x = int.Parse(match.Groups["x"].Value, CultureInfo.InvariantCulture);
                var y = int.Parse(match.Groups["y"].Value, CultureInfo.InvariantCulture);

                monitors.Add(new MonitorInfo(name, width, height, x, y, isPrimary));
            }

            return monitors;
        }
        catch
        {
            return Array.Empty<MonitorInfo>();
        }
    }

    /// <summary>
    /// Constructs Chromium command-line parameters that control window position and size. The method
    /// prefers explicit environment overrides but falls back to the detected monitor geometry so each
    /// browser instance occupies a deterministic area of the desktop.
    /// </summary>
    public static List<string> BuildBrowserLaunchArgs(string? positionOverride, string? sizeOverride, MonitorInfo? monitor)
    {
        var args = new List<string> { "--start-maximized" };

        int? posX = null, posY = null, width = null, height = null;

        if (!TryParsePair(positionOverride, out posX, out posY) && monitor.HasValue)
        {
            posX = monitor.Value.X;
            posY = monitor.Value.Y;
        }

        if (!TryParsePair(sizeOverride, out width, out height) && monitor.HasValue)
        {
            width = monitor.Value.Width;
            height = monitor.Value.Height;
        }

        if (posX.HasValue && posY.HasValue)
        {
            args.Add($"--window-position={posX.Value},{posY.Value}");
        }

        if (width.HasValue && height.HasValue)
        {
            args.Add($"--window-size={width.Value},{height.Value}");
        }

        return args;
    }

    /// <summary>
    /// Attempts to parse a <c>"number,number"</c> string (e.g. axis or width/height) used for positioning
    /// browser windows. The method is intentionally tolerant: it returns <c>false</c> when parsing fails and
    /// leaves the nullable out parameters unset so the caller can fall back to monitor defaults.
    /// </summary>
    private static bool TryParsePair(string? value, out int? first, out int? second)
    {
        first = null;
        second = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var parts = value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2)
        {
            return false;
        }

        if (int.TryParse(parts[0], out var firstValue) && int.TryParse(parts[1], out var secondValue))
        {
            first = firstValue;
            second = secondValue;
            return true;
        }

        return false;
    }
}
