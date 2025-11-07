using System;
using System.IO;
using System.Threading;

namespace UiTests.Utils;

/// <summary>
/// Lightweight file logger for ad-hoc diagnostics during UI test debugging.
/// </summary>
public static class DebugLogger
{
    private static readonly object SyncRoot = new();
    private static string? _logFilePath;
    private static int _initialized;
    private static readonly AsyncLocal<bool?> ScopeEnabled = new();
    private static readonly bool DefaultEnabled = ResolveDefaultEnabled();

    private static string ResolveLogFilePath()
    {
        if (_logFilePath is not null)
        {
            return _logFilePath;
        }

        var path = Environment.GetEnvironmentVariable("UITESTS_DEBUG_LOG");
        if (string.IsNullOrWhiteSpace(path))
        {
            path = Path.Combine(AppContext.BaseDirectory, "ui-tests-debug.log");
        }

        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(directory) && !Directory.Exists(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _logFilePath = path;
        return _logFilePath;
    }

    /// <summary>
    /// Clears the current log file.
    /// </summary>
    public static void Reset()
    {
        if (!IsEnabled)
        {
            return;
        }

        lock (SyncRoot)
        {
            var path = ResolveLogFilePath();
            File.WriteAllText(path, string.Empty);
            Interlocked.Exchange(ref _initialized, 1);
        }
    }

    /// <summary>
    /// Appends a message to the debug log with a UTC timestamp.
    /// </summary>
    public static void Log(string message)
    {
        if (!IsEnabled)
        {
            return;
        }

        lock (SyncRoot)
        {
            var path = ResolveLogFilePath();
            if (Interlocked.CompareExchange(ref _initialized, 1, 0) == 0 && !File.Exists(path))
            {
                File.WriteAllText(path, string.Empty);
            }
            var line = $"{DateTimeOffset.UtcNow:O} {message}";
            File.AppendAllText(path, line + Environment.NewLine);
        }
    }

    /// <summary>
    /// Disables or enables logging within the current async context.
    /// </summary>
    public static IDisposable PushScope(bool enabled)
        => new LoggerScope(enabled);

    /// <summary>
    /// Returns true when logging is enabled for the current async context.
    /// </summary>
    public static bool IsEnabled => ScopeEnabled.Value ?? DefaultEnabled;

    private static bool ResolveDefaultEnabled()
    {
        var raw = Environment.GetEnvironmentVariable("UITESTS_DEBUG_LOG_DEFAULT");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return false;
        }

        if (raw.Equals("1", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return bool.TryParse(raw, out var parsed) && parsed;
    }

    private sealed class LoggerScope : IDisposable
    {
        private readonly bool? _previous;

        public LoggerScope(bool enabled)
        {
            _previous = ScopeEnabled.Value;
            ScopeEnabled.Value = enabled;
        }

        public void Dispose()
        {
            ScopeEnabled.Value = _previous;
        }
    }
}
