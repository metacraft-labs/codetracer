using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.Tests.ProgramAgnostic;

/// <summary>
/// Tests for layout file resilience - verifying the app can recover from
/// corrupt or invalid layout configuration files.
///
/// NOTE: These tests run in isolated config directories (via XDG_CONFIG_HOME),
/// so they cannot interfere with each other or leave corrupted files behind.
/// </summary>
public static class LayoutResilienceTests
{
    // Get the config directory from XDG_CONFIG_HOME (set by test executor)
    // or fall back to the default location
    private static string GetConfigDir()
    {
        var xdgConfig = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (!string.IsNullOrEmpty(xdgConfig))
        {
            return Path.Combine(xdgConfig, "codetracer");
        }
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".config", "codetracer");
    }

    private static string GetLayoutPath() => Path.Combine(GetConfigDir(), "default_layout.json");

    /// <summary>
    /// Corrupt a layout file with invalid JSON.
    /// </summary>
    private static void CorruptLayoutFile(string layoutPath)
    {
        var dir = Path.GetDirectoryName(layoutPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }
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
            root = new { content = Array.Empty<object>() }
        };
        File.WriteAllText(layoutPath, JsonSerializer.Serialize(invalidLayout, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>
    /// Test that verifies the app can recover from a layout file with corrupted JSON.
    /// </summary>
    public static async Task RecoveryFromCorruptedJson(IPage page)
    {
        var layoutPath = GetLayoutPath();
        CorruptLayoutFile(layoutPath);

        await page.ReloadAsync();
        await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });

        var layout = page.Locator(".lm_goldenlayout");
        if (!await layout.IsVisibleAsync())
        {
            throw new Exception("Layout did not become visible after recovery from corrupted JSON");
        }

        var layoutContent = page.Locator(".lm_content");
        if (!await layoutContent.IsVisibleAsync())
        {
            throw new Exception("Layout content is not visible after recovery");
        }

        // Verify the layout file was restored to valid JSON
        await Task.Delay(2000);

        if (File.Exists(layoutPath))
        {
            var content = await File.ReadAllTextAsync(layoutPath);
            try
            {
                var parsed = JsonDocument.Parse(content);
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

    /// <summary>
    /// Test that verifies the app can recover from a layout file with invalid structure.
    /// </summary>
    public static async Task RecoveryFromInvalidStructure(IPage page)
    {
        var layoutPath = GetLayoutPath();
        CreateInvalidStructureLayoutFile(layoutPath);

        await page.ReloadAsync();
        await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });

        var layout = page.Locator(".lm_goldenlayout");
        if (!await layout.IsVisibleAsync())
        {
            throw new Exception("Layout did not become visible after recovery from invalid structure");
        }
    }

    /// <summary>
    /// Test that verifies the app can recover from a layout file missing the type property.
    /// </summary>
    public static async Task RecoveryFromMissingType(IPage page)
    {
        var layoutPath = GetLayoutPath();
        CreateMissingTypeLayoutFile(layoutPath);

        await page.ReloadAsync();
        await page.WaitForSelectorAsync(".lm_goldenlayout", new PageWaitForSelectorOptions { Timeout = 20000 });

        var layout = page.Locator(".lm_goldenlayout");
        if (!await layout.IsVisibleAsync())
        {
            throw new Exception("Layout did not become visible after recovery from missing type");
        }
    }

    /// <summary>
    /// Sanity check that normal operation works with a valid layout.
    /// </summary>
    public static async Task NormalOperationWithValidLayout(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var goldenLayout = page.Locator(".lm_goldenlayout");
        if (!await goldenLayout.IsVisibleAsync())
        {
            throw new Exception("GoldenLayout is not visible");
        }

        var tabs = page.Locator(".lm_tab");
        var tabCount = await tabs.CountAsync();
        if (tabCount == 0)
        {
            throw new Exception("No tabs found in the layout");
        }

        var panels = page.Locator(".lm_stack");
        var panelCount = await panels.CountAsync();
        if (panelCount == 0)
        {
            throw new Exception("No panel stacks found in the layout");
        }
    }
}
