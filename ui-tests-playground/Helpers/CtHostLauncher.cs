using System.Diagnostics;
using System.Globalization;
using System.Net.Http;

namespace UiTestsPlayground.Helpers;

/// <summary>
/// Encapsulates the logic for launching and monitoring <c>ct host</c> processes used by the browser-based UI tests.
/// </summary>
internal static class CtHostLauncher
{
    /// <summary>
    /// Starts a <c>ct host</c> process that serves the CodeTracer UI over HTTP and WebSockets.
    /// </summary>
    public static Process StartHostProcess(int port, int backendPort, int frontendPort, string tracePath, string label)
    {
        var psi = new ProcessStartInfo(CodetracerLauncher.CtPath)
        {
            WorkingDirectory = CodetracerLauncher.CtInstallDir,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        psi.ArgumentList.Add("host");
        psi.ArgumentList.Add($"--port={port.ToString(CultureInfo.InvariantCulture)}");
        psi.ArgumentList.Add($"--backend-socket-port={backendPort.ToString(CultureInfo.InvariantCulture)}");
        psi.ArgumentList.Add($"--frontend-socket={frontendPort.ToString(CultureInfo.InvariantCulture)}");
        psi.ArgumentList.Add(tracePath);

        var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start ct host.");

        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await process.StandardOutput.ReadLineAsync()) is not null)
                {
                    Console.WriteLine($"[ct host:{label}] {line}");
                }
            }
            catch
            {
                // Ignore logging failures - the process lifetime is monitored elsewhere.
            }
        });

        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await process.StandardError.ReadLineAsync()) is not null)
                {
                    Console.Error.WriteLine($"[ct host:{label}] {line}");
                }
            }
            catch
            {
                // Ignore logging failures.
            }
        });

        return process;
    }

    /// <summary>
    /// Polls the host HTTP endpoint until it responds successfully or the timeout expires.
    /// </summary>
    public static async Task WaitForServerAsync(int port, TimeSpan timeout, string label)
    {
        using var client = new HttpClient();
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var response = await client.GetAsync($"http://localhost:{port}");
                if (response.IsSuccessStatusCode)
                {
                    return;
                }
            }
            catch
            {
                // keep retrying
            }

            await Task.Delay(250);
        }

        throw new TimeoutException($"[{label}] ct host did not become ready on port {port} within {timeout.TotalSeconds} seconds.");
    }
}
