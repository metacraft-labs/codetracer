using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.Utils;

namespace UiTests.Tests.ProgramAgnostic;

/// <summary>
/// Tests for layout file resilience - verifying the app can recover from
/// corrupt or invalid layout configuration files.
/// </summary>
public static class LayoutResilienceTests
{
    // Get the user layout directory (same logic as in frontend/config.nim)
    private static string UserLayoutDir => Path.Combine(
        Environment.GetEnvironmentVariable("XDG_CONFIG_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config"),
        "codetracer");

    private static string DefaultLayoutPath => Path.Combine(UserLayoutDir, "default_layout.json");
    private static string DefaultEditLayoutPath => Path.Combine(UserLayoutDir, "default_edit_layout.json");
    private const string BackupSuffix = ".backup_test";

    /// <summary>
    /// Backup a layout file if it exists.
    /// </summary>
    private static void BackupLayoutFile(string layoutPath)
    {
        if (File.Exists(layoutPath))
        {
            File.Copy(layoutPath, layoutPath + BackupSuffix, overwrite: true);
        }
    }

    /// <summary>
    /// Restore a layout file from backup.
    /// </summary>
    private static void RestoreLayoutFile(string layoutPath)
    {
        var backupPath = layoutPath + BackupSuffix;
        if (File.Exists(backupPath))
        {
            File.Copy(backupPath, layoutPath, overwrite: true);
            File.Delete(backupPath);
        }
    }

    /// <summary>
    /// Corrupt a layout file with invalid JSON.
    /// </summary>
    private static void CorruptLayoutFile(string layoutPath)
    {
        // Ensure directory exists
        var dir = Path.GetDirectoryName(layoutPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        // Write invalid JSON that can't be parsed
        File.WriteAllText(layoutPath, "{ invalid json content without closing brace");
    }

    /// <summary>
    /// Create a layout file with valid JSON but invalid structure (missing root).
    /// </summary>
    private static void CreateInvalidStructureLayoutFile(string layoutPath)
    {
        var dir = Path.GetDirectoryName(layoutPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        var invalidLayout = new
        {
            settings = new { constrainDragToContainer = true },
            dimensions = new { borderWidth = 2 },
            // Missing 'root' property - this should trigger validation failure
            notRoot = new { type = "row", content = Array.Empty<object>() }
        };
        File.WriteAllText(layoutPath, JsonSerializer.Serialize(invalidLayout, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>
    /// Create a layout file with root but missing type property.
    /// </summary>
    private static void CreateMissingTypeLayoutFile(string layoutPath)
    {
        var dir = Path.GetDirectoryName(layoutPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        var invalidLayout = new
        {
            settings = new { },
            root = new
            {
                // Missing 'type' property
                content = Array.Empty<object>()
            }
        };
        File.WriteAllText(layoutPath, JsonSerializer.Serialize(invalidLayout, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>
    /// Test that verifies the app can recover from a layout file with corrupted JSON.
    /// This test should be run with a trace loaded (debug mode).
    /// </summary>
    public static async Task RecoveryFromCorruptedJsonInDebugMode(IPage page)
    {
        // Backup the current layout file
        BackupLayoutFile(DefaultLayoutPath);

        try
        {
            // Corrupt the layout file
            CorruptLayoutFile(DefaultLayoutPath);

            // Reload the page to trigger layout loading
            await page.ReloadAsync();

            // Wait for the layout to initialize (the app should recover)
            await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });

            // Verify the layout is visible
            var layout = page.Locator(".lm_goldenlayout");
            if (!await layout.IsVisibleAsync())
            {
                throw new Exception("Layout did not become visible after recovery from corrupted JSON");
            }

            // Verify layout content is present
            var layoutContent = page.Locator(".lm_content");
            if (!await layoutContent.IsVisibleAsync())
            {
                throw new Exception("Layout content is not visible after recovery");
            }

            // Verify the layout file was restored to valid JSON
            await Task.Delay(2000); // Wait for file operations to complete

            if (File.Exists(DefaultLayoutPath))
            {
                var content = await File.ReadAllTextAsync(DefaultLayoutPath);

                // Should be valid JSON
                try
                {
                    var parsed = JsonDocument.Parse(content);

                    // Should have the required 'root' property
                    if (!parsed.RootElement.TryGetProperty("root", out var root))
                    {
                        throw new Exception("Restored layout file is missing 'root' property");
                    }

                    if (!root.TryGetProperty("type", out _))
                    {
                        throw new Exception("Restored layout file root is missing 'type' property");
                    }
                }
                catch (JsonException ex)
                {
                    throw new Exception($"Restored layout file is not valid JSON: {ex.Message}");
                }
            }
        }
        finally
        {
            // Restore the original layout file
            RestoreLayoutFile(DefaultLayoutPath);
        }
    }

    /// <summary>
    /// Test that verifies the app can recover from a layout file with invalid structure.
    /// </summary>
    public static async Task RecoveryFromInvalidStructure(IPage page)
    {
        BackupLayoutFile(DefaultLayoutPath);

        try
        {
            CreateInvalidStructureLayoutFile(DefaultLayoutPath);

            await page.ReloadAsync();

            await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });

            var layout = page.Locator(".lm_goldenlayout");
            if (!await layout.IsVisibleAsync())
            {
                throw new Exception("Layout did not become visible after recovery from invalid structure");
            }
        }
        finally
        {
            RestoreLayoutFile(DefaultLayoutPath);
        }
    }

    /// <summary>
    /// Test that verifies the app can recover from a layout file missing the type property.
    /// </summary>
    public static async Task RecoveryFromMissingType(IPage page)
    {
        BackupLayoutFile(DefaultLayoutPath);

        try
        {
            CreateMissingTypeLayoutFile(DefaultLayoutPath);

            await page.ReloadAsync();

            await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });

            var layout = page.Locator(".lm_goldenlayout");
            if (!await layout.IsVisibleAsync())
            {
                throw new Exception("Layout did not become visible after recovery from missing type");
            }
        }
        finally
        {
            RestoreLayoutFile(DefaultLayoutPath);
        }
    }

    /// <summary>
    /// Test that verifies UI functionality is preserved after layout recovery.
    /// </summary>
    public static async Task UiFunctionalityAfterRecovery(IPage page)
    {
        BackupLayoutFile(DefaultLayoutPath);

        try
        {
            CorruptLayoutFile(DefaultLayoutPath);

            await page.ReloadAsync();

            await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });
            await Task.Delay(1000);

            // Test that tabs are clickable
            var tabs = page.Locator(".lm_tab");
            var tabCount = await tabs.CountAsync();

            if (tabCount > 0)
            {
                await tabs.First.ClickAsync();
                await Task.Delay(500);

                // Verify the layout is still responsive
                var layout = page.Locator(".lm_goldenlayout");
                if (!await layout.IsVisibleAsync())
                {
                    throw new Exception("Layout became non-responsive after clicking tabs");
                }
            }

            // Test that splitters exist (for resize capability)
            var splitters = page.Locator(".lm_splitter");
            var splitterCount = await splitters.CountAsync();

            if (splitterCount > 0)
            {
                var firstSplitter = splitters.First;
                if (!await firstSplitter.IsVisibleAsync())
                {
                    throw new Exception("Splitters are not visible after recovery");
                }
            }
        }
        finally
        {
            RestoreLayoutFile(DefaultLayoutPath);
        }
    }

    /// <summary>
    /// Sanity check that normal operation works with a valid layout.
    /// </summary>
    public static async Task NormalOperationWithValidLayout(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        // Verify the layout is visible
        var goldenLayout = page.Locator(".lm_goldenlayout");
        if (!await goldenLayout.IsVisibleAsync())
        {
            throw new Exception("GoldenLayout is not visible");
        }

        // Should have at least one tab
        var tabs = page.Locator(".lm_tab");
        var tabCount = await tabs.CountAsync();
        if (tabCount == 0)
        {
            throw new Exception("No tabs found in the layout");
        }

        // Should have at least one panel stack
        var panels = page.Locator(".lm_stack");
        var panelCount = await panels.CountAsync();
        if (panelCount == 0)
        {
            throw new Exception("No panel stacks found in the layout");
        }
    }
}
