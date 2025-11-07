using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace UiTests.Infrastructure;

internal readonly record struct MonitorInfo(string Name, int Width, int Height, int X, int Y, bool IsPrimary, string? Edid);

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
            psi.ArgumentList.Add("xrandr --query --verbose");

            using var process = Process.Start(psi);
            if (process is null)
            {
                return Array.Empty<MonitorInfo>();
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(2000);

            var monitors = ParseMonitors(output);

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

        var hasPositionOverride = TryParsePair(positionOverride, out posX, out posY);
        if (!hasPositionOverride && monitor.HasValue)
        {
            posX = monitor.Value.X;
            posY = monitor.Value.Y;
        }

        var hasSizeOverride = TryParsePair(sizeOverride, out width, out height);

        if (posX.HasValue && posY.HasValue)
        {
            args.Add($"--window-position={posX.Value},{posY.Value}");
        }

        if (hasSizeOverride && width.HasValue && height.HasValue)
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

    private static IReadOnlyList<MonitorInfo> ParseMonitors(string output)
    {
        var monitors = new List<MonitorInfo>();
        MonitorParserState? current = null;

        void FinalizeCurrent()
        {
            if (current is null)
            {
                return;
            }

            monitors.Add(new MonitorInfo(
                current.Name,
                current.Width,
                current.Height,
                current.X,
                current.Y,
                current.IsPrimary,
                current.GetEdid()));

            current = null;
        }

        foreach (var rawLine in output.Split('\n'))
        {
            var line = rawLine.TrimEnd();
            if (string.IsNullOrWhiteSpace(line))
            {
                if (current is not null)
                {
                    current.IsReadingEdid = false;
                }
                continue;
            }

            if (line.Contains(" connected", StringComparison.Ordinal))
            {
                FinalizeCurrent();

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

                current = new MonitorParserState(name, width, height, x, y, isPrimary);
                continue;
            }

            if (current is null)
            {
                continue;
            }

            var trimmed = rawLine.Trim();
            if (trimmed.StartsWith("EDID", StringComparison.OrdinalIgnoreCase))
            {
                current.BeginEdid();
                continue;
            }

            if (current.IsReadingEdid)
            {
                if (string.IsNullOrWhiteSpace(trimmed))
                {
                    current.IsReadingEdid = false;
                    continue;
                }

                var hex = trimmed.Replace(" ", string.Empty);
                if (hex.All(uriChar => Uri.IsHexDigit(uriChar)))
                {
                    current.AppendEdid(hex);
                }
                else
                {
                    current.IsReadingEdid = false;
                }
            }
        }

        FinalizeCurrent();
        return monitors;
    }

    private sealed class MonitorParserState
    {
        private readonly StringBuilder _edidBuilder = new();

        public MonitorParserState(string name, int width, int height, int x, int y, bool isPrimary)
        {
            Name = name;
            Width = width;
            Height = height;
            X = x;
            Y = y;
            IsPrimary = isPrimary;
        }

        public string Name { get; }
        public int Width { get; }
        public int Height { get; }
        public int X { get; }
        public int Y { get; }
        public bool IsPrimary { get; }
        public bool IsReadingEdid { get; set; }

        public void BeginEdid()
        {
            _edidBuilder.Clear();
            IsReadingEdid = true;
        }

        public void AppendEdid(string hex)
        {
            _edidBuilder.Append(hex);
        }

        public string? GetEdid()
        {
            return _edidBuilder.Length > 0 ? _edidBuilder.ToString() : null;
        }
    }
}
