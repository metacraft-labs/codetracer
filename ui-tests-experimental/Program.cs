using System;
using System.Diagnostics;
using System.Threading.Tasks;
using OpenQA.Selenium;
using UtTestsExperimentalConsoleAppication.Helpers;

namespace UtTestsExperimentalConsoleAppication;

// Console app launching CodeTracer via Selenium.
class Program
{
    public static async Task Main()
    {
        try
        {
            if (!CodetracerLauncher.IsCtAvailable)
            {
                Console.WriteLine($"ct executable not found at {CodetracerLauncher.CtPath}. Build CodeTracer or set CODETRACER_E2E_CT_PATH.");
                return;
            }

            var browser = await PlaywrightLauncher.LaunchAsync("noir_space_ship");
            var page = await PlaywrightLauncher.GetAppPageAsync(browser, titleContains: "CodeTracer");

            for (int i = 0; i < 5; i++)
            {
                await page.Locator("#menu-root").ClickAsync();
                Thread.Sleep(1000);
            }
        }
        finally
        {
            var kill = new ProcessStartInfo("just")
            {
                ArgumentList = { "stop" },
            };

            var process2 = Process.Start(kill)!;
        }
    }
}
