using System;
using System.Threading.Tasks;
using OpenQA.Selenium;
using UtTestsExperimentalConsoleAppication.Helpers;

namespace UtTestsExperimentalConsoleAppication;

// Console app launching CodeTracer via Selenium.
class Program
{
    public static async Task Main()
    {
        if (!CodetracerLauncher.IsCtAvailable)
        {
            Console.WriteLine($"ct executable not found at {CodetracerLauncher.CtPath}. Build CodeTracer or set CODETRACER_E2E_CT_PATH.");
            return;
        }

        var driver = await PlaywrightCodetracerLauncher.LaunchAsync("noir_space_ship");
        await Task.Delay(TimeSpan.FromSeconds(10));

        // bool isVisible = false;
        try
        {
            // await driver. ClickAsync("div");
            // var element = driver.FindElement(By.CssSelector(".menu-logo-img"));
            // isVisible = element.Displayed;
        }
        catch (NoSuchElementException)
        {
            // Element not found; isVisible remains false.
        }
    }
}
