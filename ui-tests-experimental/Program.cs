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

            var window = await PlaywrightCodetracerLauncher.LaunchAsync("noir_space_ship");

            try
            {
                Console.WriteLine($"received driver: {window}");
                // await driver. ClickAsync("div");
                // var element = driver.FindElement(By.CssSelector(".menu-logo-img"));
                // isVisible = element.Displayed;
            }
            catch (NoSuchElementException)
            {
                // Element not found; isVisible remains false.
            }

            var driver = window.Contexts[0].Pages[0];

            for (int i = 0; i < 5; i++)
            {
                await driver.Locator("#menu-root").ClickAsync();
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
