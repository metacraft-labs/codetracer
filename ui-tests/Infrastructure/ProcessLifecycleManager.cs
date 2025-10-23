using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace UiTests.Infrastructure;

internal interface IProcessLifecycleManager
{
    void ReportProcessCounts(string scope);
    void KillProcesses(string reason);
}

internal sealed class ProcessLifecycleManager : IProcessLifecycleManager
{
    private readonly ILogger<ProcessLifecycleManager> _logger;
    private static readonly string[] ProcessNames = { "ct", "electron", "backend-manager", "virtualization-layers", "node" };

    public ProcessLifecycleManager(ILogger<ProcessLifecycleManager> logger)
    {
        _logger = logger;
    }

    public void ReportProcessCounts(string scope)
    {
        foreach (var name in ProcessNames)
        {
            try
            {
                var count = Process.GetProcessesByName(name).Length;
                _logger.LogInformation("[{Scope}] Process '{Name}': {Count} instance(s).", scope, name, count);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "[{Scope}] Failed to inspect process '{Name}'.", scope, name);
            }
        }
    }

    public void KillProcesses(string reason)
    {
        foreach (var name in ProcessNames)
        {
            foreach (var process in Process.GetProcessesByName(name))
            {
                try
                {
                    _logger.LogInformation("[{Reason}] Killing process {Name} (PID {Pid}).", reason, name, process.Id);
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5000);
                }
                catch (Exception ex)
                {
                    _logger.LogDebug(ex, "[{Reason}] Failed to terminate process {Name} (PID {Pid}).", reason, name, process.Id);
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
    }
}
