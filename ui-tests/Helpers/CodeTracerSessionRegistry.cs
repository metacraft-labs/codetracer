using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace UiTests.Helpers;

/// <summary>
/// Tracks all CodeTracer sessions created during a UI test run so they
/// can be terminated reliably once the run completes.
/// </summary>
internal static class CodeTracerSessionRegistry
{
    private static readonly ConcurrentDictionary<int, CodeTracerSession> Sessions = new();

    /// <summary>
    /// Registers a newly created session so that it will be cleaned up
    /// when the process exits.
    /// </summary>
    /// <param name="session">The session to track.</param>
    public static void Register(CodeTracerSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        Sessions[session.RootProcess.Id] = session;
    }

    /// <summary>
    /// Terminates a specific session and removes it from the registry.
    /// The cleanup logic only runs once even if invoked multiple times.
    /// </summary>
    public static async ValueTask TerminateSessionAsync(CodeTracerSession session)
    {
        if (session is null)
        {
            return;
        }

        if (!session.TryMarkTerminated())
        {
            return;
        }

        Sessions.TryRemove(session.RootProcess.Id, out _);

        try
        {
            await ProcessTreeTerminator.TerminateAsync(session);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to terminate CodeTracer session {session.RootProcess.Id}: {ex}");
        }
    }

    /// <summary>
    /// Terminates all active sessions that were registered during the
    /// current UI test run.
    /// </summary>
    public static async Task TerminateAllAsync()
    {
        List<CodeTracerSession> snapshot = Sessions.Values.ToList();
        foreach (var session in snapshot)
        {
            await TerminateSessionAsync(session);
        }
    }
}
