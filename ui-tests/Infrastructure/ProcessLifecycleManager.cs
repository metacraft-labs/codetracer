using System.Collections.Concurrent;
using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace UiTests.Infrastructure;

internal interface IProcessLifecycleManager
{
    void ReportProcessCounts(string scope);
    void KillProcesses(string reason);
    void RegisterProcess(Process process, string label);
    void UnregisterProcess(int processId);
}

internal sealed class ProcessLifecycleManager : IProcessLifecycleManager
{
    private readonly ILogger<ProcessLifecycleManager> _logger;
    private static readonly string[] ProcessNames = { "ct", "electron", "backend-manager", "virtualization-layers", "node" };
    private readonly ConcurrentDictionary<int, string> _registeredProcesses = new();

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
        foreach (var entry in _registeredProcesses.ToArray())
        {
            var pid = entry.Key;
            try
            {
                Process? process = null;
                try
                {
                    process = Process.GetProcessById(pid);
                }
                catch (ArgumentException)
                {
                    _logger.LogDebug("[{Reason}] Registered process (PID {Pid}) already exited.", reason, pid);
                    continue;
                }

                _logger.LogInformation("[{Reason}] Killing process {Label} (PID {Pid}).", reason, entry.Value, pid);
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "[{Reason}] Failed to terminate registered process (PID {Pid}).", reason, pid);
            }
            finally
            {
                _registeredProcesses.TryRemove(pid, out _);
            }
        }
    }

    public void RegisterProcess(Process process, string label)
    {
        if (process is null)
        {
            return;
        }

        var name = string.IsNullOrWhiteSpace(label) ? process.ProcessName : label;
        if (_registeredProcesses.TryAdd(process.Id, name))
        {
            _logger.LogDebug("Registered process {Label} (PID {Pid}) for cleanup.", name, process.Id);
        }
    }

    public void UnregisterProcess(int processId)
    {
        _registeredProcesses.TryRemove(processId, out _);
    }
}
