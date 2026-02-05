using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Playwright;
using UiTests.Configuration;
using UiTests.Execution;

namespace UiTests.Infrastructure;

/// <summary>
/// Captures diagnostic information (DOM, screenshots) when tests fail.
/// </summary>
public interface ITestDiagnosticsService
{
    /// <summary>
    /// Captures diagnostic artifacts for a failed test.
    /// </summary>
    Task CaptureFailureDiagnosticsAsync(
        IPage page,
        TestPlanEntry entry,
        Exception exception,
        int attempt);
}

public sealed class TestDiagnosticsService : ITestDiagnosticsService
{
    private readonly AppSettings _settings;
    private readonly ILogger<TestDiagnosticsService> _logger;
    private readonly string _outputDirectory;

    public TestDiagnosticsService(
        IOptions<AppSettings> settings,
        ILogger<TestDiagnosticsService> logger)
    {
        _settings = settings.Value;
        _logger = logger;

        // Use configured directory or default to ./test-diagnostics
        _outputDirectory = string.IsNullOrWhiteSpace(_settings.Runner.DiagnosticsOutput)
            ? Path.Combine(Directory.GetCurrentDirectory(), "test-diagnostics")
            : _settings.Runner.DiagnosticsOutput;
    }

    public async Task CaptureFailureDiagnosticsAsync(
        IPage page,
        TestPlanEntry entry,
        Exception exception,
        int attempt)
    {
        try
        {
            Directory.CreateDirectory(_outputDirectory);

            var timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var safeTestId = SanitizeFileName(entry.Test.Id);
            var safeScenarioId = SanitizeFileName(entry.Scenario.Id);
            var baseName = $"{timestamp}_{safeTestId}_{safeScenarioId}_{entry.Mode}_attempt{attempt}";

            // Capture DOM
            await CaptureDomAsync(page, baseName);

            // Capture screenshot
            await CaptureScreenshotAsync(page, baseName);

            // Save exception details
            await SaveExceptionDetailsAsync(baseName, entry, exception);

            _logger.LogInformation(
                "Captured diagnostics for failed test {TestId} to {OutputDir}/{BaseName}.*",
                entry.Test.Id, _outputDirectory, baseName);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to capture diagnostics for test {TestId}", entry.Test.Id);
        }
    }

    private async Task CaptureDomAsync(IPage page, string baseName)
    {
        try
        {
            var html = await page.ContentAsync();
            var filePath = Path.Combine(_outputDirectory, $"{baseName}.html");
            await File.WriteAllTextAsync(filePath, html);
            _logger.LogDebug("Saved DOM to {FilePath}", filePath);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Failed to capture DOM");
        }
    }

    private async Task CaptureScreenshotAsync(IPage page, string baseName)
    {
        try
        {
            var filePath = Path.Combine(_outputDirectory, $"{baseName}.png");
            await page.ScreenshotAsync(new PageScreenshotOptions
            {
                Path = filePath,
                FullPage = true
            });
            _logger.LogDebug("Saved screenshot to {FilePath}", filePath);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Failed to capture screenshot");
        }
    }

    private async Task SaveExceptionDetailsAsync(string baseName, TestPlanEntry entry, Exception exception)
    {
        try
        {
            var filePath = Path.Combine(_outputDirectory, $"{baseName}.txt");
            var content = $"""
                Test Failure Report
                ===================
                Test ID: {entry.Test.Id}
                Scenario ID: {entry.Scenario.Id}
                Mode: {entry.Mode}
                Timestamp: {DateTime.Now:O}

                Exception Type: {exception.GetType().FullName}
                Message: {exception.Message}

                Stack Trace:
                {exception.StackTrace}

                Inner Exception:
                {exception.InnerException?.ToString() ?? "(none)"}
                """;
            await File.WriteAllTextAsync(filePath, content);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Failed to save exception details");
        }
    }

    private static string SanitizeFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return string.Join("_", name.Split(invalid, StringSplitOptions.RemoveEmptyEntries));
    }
}
