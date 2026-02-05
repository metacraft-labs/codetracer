using System.Text;
using System.Text.RegularExpressions;
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
    /// Gets the output directory for diagnostic artifacts.
    /// </summary>
    string OutputDirectory { get; }

    /// <summary>
    /// Captures diagnostic artifacts for a failed test.
    /// </summary>
    Task CaptureFailureDiagnosticsAsync(
        IPage page,
        TestPlanEntry entry,
        Exception exception,
        int attempt);

    /// <summary>
    /// Generates a trace file path for the given test entry.
    /// </summary>
    string GetTraceFilePath(TestPlanEntry entry);
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

    public string OutputDirectory => _outputDirectory;

    public string GetTraceFilePath(TestPlanEntry entry)
    {
        Directory.CreateDirectory(_outputDirectory);
        var timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        var safeTestId = SanitizeFileName(entry.Test.Id);
        var safeScenarioId = SanitizeFileName(entry.Scenario.Id);
        return Path.Combine(_outputDirectory, $"{timestamp}_{safeTestId}_{safeScenarioId}_{entry.Mode}.trace.zip");
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

            // Capture DOM (full HTML)
            await CaptureDomAsync(page, baseName);

            // Capture condensed DOM summary (lightweight)
            await CaptureDomSummaryAsync(page, baseName);

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

    /// <summary>
    /// Captures a condensed DOM summary showing element hierarchy with IDs/classes.
    /// This is much smaller than the full HTML and focuses on structural elements.
    /// </summary>
    private async Task CaptureDomSummaryAsync(IPage page, string baseName)
    {
        try
        {
            // JavaScript to extract DOM structure with relevant attributes
            var summaryScript = """
                (() => {
                    const result = [];
                    const indent = (level) => '  '.repeat(level);

                    // Selectors for CodeTracer components we care about
                    const componentSelectors = [
                        'eventLogComponent', 'callTraceComponent', 'editorComponent',
                        'sourceComponent', 'traceLogComponent', 'variablesComponent',
                        'consoleComponent', 'searchComponent', 'navbarComponent',
                        'watchComponent', 'sidebarComponent', 'statusbarComponent',
                        'monaco-editor', 'layout-container', 'split-pane'
                    ];

                    function isRelevant(el) {
                        if (!el || el.nodeType !== 1) return false;
                        const id = el.id || '';
                        const className = el.className || '';
                        const classStr = typeof className === 'string' ? className : className.baseVal || '';

                        // Include elements with IDs
                        if (id) return true;

                        // Include elements with component-related classes
                        for (const sel of componentSelectors) {
                            if (id.includes(sel) || classStr.includes(sel)) return true;
                        }

                        // Include common structural elements
                        const tag = el.tagName.toLowerCase();
                        if (['main', 'nav', 'header', 'footer', 'section', 'article'].includes(tag)) return true;

                        // Include elements with data attributes
                        if (el.dataset && Object.keys(el.dataset).length > 0) return true;

                        return false;
                    }

                    function summarize(el, level = 0, maxDepth = 15) {
                        if (!el || el.nodeType !== 1 || level > maxDepth) return;

                        const tag = el.tagName.toLowerCase();
                        const id = el.id || '';
                        const className = el.className || '';
                        const classStr = typeof className === 'string' ? className : className.baseVal || '';

                        // Skip script, style, svg internals
                        if (['script', 'style', 'noscript'].includes(tag)) return;
                        if (tag === 'path' || tag === 'g' || tag === 'defs') return;

                        const relevant = isRelevant(el);

                        if (relevant) {
                            let line = indent(level) + '<' + tag;
                            if (id) line += ' id="' + id + '"';
                            if (classStr) {
                                // Truncate long class lists
                                const classes = classStr.split(/\s+/).slice(0, 5).join(' ');
                                line += ' class="' + classes + (classStr.split(/\s+/).length > 5 ? '...' : '') + '"';
                            }

                            // Include relevant data attributes
                            if (el.dataset) {
                                for (const [key, val] of Object.entries(el.dataset)) {
                                    if (val && val.length < 50) {
                                        line += ' data-' + key + '="' + val + '"';
                                    }
                                }
                            }

                            // Check visibility
                            const style = window.getComputedStyle(el);
                            if (style.display === 'none') line += ' [hidden]';
                            if (style.visibility === 'hidden') line += ' [invisible]';

                            // Show dimensions for key components
                            if (id && componentSelectors.some(s => id.includes(s))) {
                                const rect = el.getBoundingClientRect();
                                line += ` [${Math.round(rect.width)}x${Math.round(rect.height)}]`;
                            }

                            line += '>';
                            result.push(line);
                        }

                        // Always recurse into children to find nested relevant elements
                        for (const child of el.children) {
                            summarize(child, relevant ? level + 1 : level, maxDepth);
                        }
                    }

                    summarize(document.body);

                    // Also capture some quick stats
                    const stats = {
                        totalElements: document.querySelectorAll('*').length,
                        visibleInputs: document.querySelectorAll('input:not([type=hidden]), textarea, select').length,
                        buttons: document.querySelectorAll('button, [role=button]').length,
                        eventLogComponents: document.querySelectorAll('[id*=eventLogComponent]').length,
                        callTraceComponents: document.querySelectorAll('[id*=callTraceComponent]').length,
                        editorComponents: document.querySelectorAll('[id*=editorComponent]').length,
                        monacoEditors: document.querySelectorAll('.monaco-editor').length
                    };

                    return { structure: result.join('\n'), stats };
                })()
                """;

            var summary = await page.EvaluateAsync<DomSummaryResult>(summaryScript);

            var sb = new StringBuilder();
            sb.AppendLine("DOM Summary Report");
            sb.AppendLine("==================");
            sb.AppendLine();
            sb.AppendLine("Quick Stats:");
            sb.AppendLine($"  Total elements: {summary.Stats.TotalElements}");
            sb.AppendLine($"  Visible inputs: {summary.Stats.VisibleInputs}");
            sb.AppendLine($"  Buttons: {summary.Stats.Buttons}");
            sb.AppendLine($"  Event Log components: {summary.Stats.EventLogComponents}");
            sb.AppendLine($"  Call Trace components: {summary.Stats.CallTraceComponents}");
            sb.AppendLine($"  Editor components: {summary.Stats.EditorComponents}");
            sb.AppendLine($"  Monaco editors: {summary.Stats.MonacoEditors}");
            sb.AppendLine();
            sb.AppendLine("Structure (elements with IDs or component classes):");
            sb.AppendLine("---------------------------------------------------");
            sb.AppendLine(summary.Structure);

            var filePath = Path.Combine(_outputDirectory, $"{baseName}.summary.txt");
            await File.WriteAllTextAsync(filePath, sb.ToString());
            _logger.LogDebug("Saved DOM summary to {FilePath}", filePath);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Failed to capture DOM summary");
        }
    }

    private sealed class DomSummaryResult
    {
        public string Structure { get; set; } = string.Empty;
        public DomStats Stats { get; set; } = new();
    }

    private sealed class DomStats
    {
        public int TotalElements { get; set; }
        public int VisibleInputs { get; set; }
        public int Buttons { get; set; }
        public int EventLogComponents { get; set; }
        public int CallTraceComponents { get; set; }
        public int EditorComponents { get; set; }
        public int MonacoEditors { get; set; }
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
