using System;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UtTestsExperimentalConsoleAppication.Helpers;

namespace UtTestsExperimentalConsoleAppication;

// Console app launching CodeTracer via Playwright.
class Program
{
    public static async Task Main()
    {
        if (!PlaywrightCodetracerLauncher.IsCtAvailable)
        {
            Console.WriteLine($"ct executable not found at {PlaywrightCodetracerLauncher.CtPath}. Build CodeTracer or set CODETRACER_E2E_CT_PATH.");
            return;
        }

        var page = await PlaywrightCodetracerLauncher.LaunchAsync("noir_space_ship");
        await page.WaitForSelectorAsync(".menu-logo-img", new() { Timeout = 10_000 });
    }
}
