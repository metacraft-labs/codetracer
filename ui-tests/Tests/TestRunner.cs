using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.Helpers;

namespace UiTests.Tests;

/// <summary>
/// Simple test runner that launches CodeTracer and executes the page object tests.
/// </summary>
public static class TestRunner
{
    public static async Task RunAsync()
    {
        if (!PlaywrightLauncher.IsCtAvailable)
        {
            Console.WriteLine($"ct executable not found at {PlaywrightLauncher.CtPath}. Build CodeTracer or set CODETRACER_E2E_CT_PATH.");
            return;
        }

        await using var session = await PlaywrightLauncher.LaunchAsync("noir_space_ship");
        var page = await PlaywrightLauncher.GetAppPageAsync(session.Browser, titleContains: "CodeTracer");

        // await PageObjectTests.PageObjectsSmokeTestAsync(page);

        await NoirSpaceShipTests.JumpToAllEvents(page);
        await NoirSpaceShipTests.EditorLoadedMainNrFile(page);
        await NoirSpaceShipTests.CreateSimpleTracePoint(page);
    }
}
