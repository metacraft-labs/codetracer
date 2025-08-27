using System.Threading.Tasks;
using Microsoft.Playwright;
using NUnit.Framework;
using UiTestsExperimental.Helpers;

namespace UiTestsExperimental.Tests
{
    public class MenuLogoTests
    {
        [Test]
        public async Task MenuLogoAppearsWithin10Seconds()
        {
            var page = await CodetracerLauncher.LaunchAsync("noir_space_ship");
            await page.WaitForSelectorAsync(".menu-logo-img", new() { Timeout = 10_000 });
            Assert.Pass("The menu logo appeared within 10 seconds.");
        }
    }
}
