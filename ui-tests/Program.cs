using System.Diagnostics;
using System.Threading.Tasks;
using UtTestsExperimentalConsoleAppication.Tests;

namespace UtTestsExperimentalConsoleAppication;

class Program
{
    public static async Task Main()
    {
        try
        {
            await TestRunner.RunAsync();
        }
        finally
        {
            try
            {
                var kill = new ProcessStartInfo("just")
                {
                    ArgumentList = { "stop" },
                };
                Process.Start(kill);
            }
            catch
            {
                // Ignore cleanup failures when 'just' is not installed.
            }
        }
    }
}
