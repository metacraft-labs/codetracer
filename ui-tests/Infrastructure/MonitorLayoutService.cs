using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace UiTests.Infrastructure;

internal readonly record struct MonitorInfo(string Name, int Width, int Height, int X, int Y, bool IsPrimary);

internal interface IMonitorLayoutService
{
    IReadOnlyList<MonitorInfo> DetectMonitors();
    IReadOnlyList<string> BuildBrowserLaunchArgs(string? positionOverride, string? sizeOverride, MonitorInfo? monitor);
}

internal sealed class MonitorLayoutService : IMonitorLayoutService
{
    private readonly ILogger<MonitorLayoutService> _logger;

    public MonitorLayoutService(ILogger<MonitorLayoutService> logger)
    {
        _logger = logger;
    }

    public IReadOnlyList<MonitorInfo> DetectMonitors()
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
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Failed to detect monitors via xrandr.");
            return Array.Empty<MonitorInfo>();
        }
    }

    public IReadOnlyList<string> BuildBrowserLaunchArgs(string? positionOverride, string? sizeOverride, MonitorInfo? monitor)
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
