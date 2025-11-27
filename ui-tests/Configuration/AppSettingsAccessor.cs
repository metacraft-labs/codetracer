using System;

namespace UiTests.Configuration;

/// <summary>
/// Simple static accessor for settings so page objects can respect run-time configuration
/// without plumbing DI through every test method.
/// </summary>
internal static class AppSettingsAccessor
{
    private static AppSettings? _current;
    private static readonly object SyncRoot = new();

    public static AppSettings? TryGetCurrent()
    {
        lock (SyncRoot)
        {
            return _current;
        }
    }

    public static void Initialize(AppSettings settings)
    {
        if (settings is null)
        {
            throw new ArgumentNullException(nameof(settings));
        }

        lock (SyncRoot)
        {
            _current = settings;
        }
    }
}
