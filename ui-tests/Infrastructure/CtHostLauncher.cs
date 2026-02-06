using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using Microsoft.Extensions.Logging;

namespace UiTests.Infrastructure;

internal interface ICtHostLauncher
{
    Process StartHostProcess(int port, int backendPort, int frontendPort, string tracePath, string label, bool emitOutput, string? isolatedConfigDir = null);
    Task WaitForServerAsync(int port, TimeSpan timeout, string label, CancellationToken cancellationToken);
}

internal sealed class CtHostLauncher : ICtHostLauncher
{
    private readonly ICodetracerLauncher _launcher;
    private readonly ILogger<CtHostLauncher> _logger;

    public CtHostLauncher(ICodetracerLauncher launcher, ILogger<CtHostLauncher> logger)
    {
        _launcher = launcher;
        _logger = logger;
    }

    public Process StartHostProcess(int port, int backendPort, int frontendPort, string tracePath, string label, bool emitOutput, string? isolatedConfigDir = null)
    {
        var psi = new ProcessStartInfo(_launcher.CtPath)
        {
            WorkingDirectory = _launcher.CtInstallDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        psi.ArgumentList.Add("host");
        psi.ArgumentList.Add($"--port={port.ToString(CultureInfo.InvariantCulture)}");
        psi.ArgumentList.Add($"--backend-socket-port={backendPort.ToString(CultureInfo.InvariantCulture)}");
        psi.ArgumentList.Add($"--frontend-socket={frontendPort.ToString(CultureInfo.InvariantCulture)}");
        psi.ArgumentList.Add(tracePath);

        // Isolate config directory to prevent test interference
        if (!string.IsNullOrEmpty(isolatedConfigDir))
        {
            psi.EnvironmentVariables["XDG_CONFIG_HOME"] = isolatedConfigDir;
        }

        var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start ct host.");

        if (emitOutput)
        {
            _ = Task.Run(async () => await PumpAsync(process.StandardOutput, line => _logger.LogInformation("[ct host:{Label}] {Line}", label, line)));
        }
        else
        {
            _ = Task.Run(async () => await PumpAsync(process.StandardOutput, _ => { }));
        }

        _ = Task.Run(async () => await PumpAsync(process.StandardError, line => _logger.LogError("[ct host:{Label}] {Line}", label, line)));

        return process;
    }

    public async Task WaitForServerAsync(int port, TimeSpan timeout, string label, CancellationToken cancellationToken)
    {
        using var client = new HttpClient();
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                using var response = await client.GetAsync($"http://localhost:{port}", cancellationToken);
                if (response.IsSuccessStatusCode)
                {
                    return;
                }
            }
            catch when (!cancellationToken.IsCancellationRequested)
            {
                // keep retrying
            }

            await Task.Delay(250, cancellationToken);
        }

        throw new TimeoutException($"[{label}] ct host did not become ready on port {port} within {timeout.TotalSeconds} seconds.");
    }

    private static async Task PumpAsync(StreamReader reader, Action<string> log)
    {
        try
        {
            string? line;
            while ((line = await reader.ReadLineAsync()) is not null)
            {
                log(line);
            }
        }
        catch
        {
            // Ignore logging failures
        }
    }
}
