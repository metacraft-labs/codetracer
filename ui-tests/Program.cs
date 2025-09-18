using System.Threading.Tasks;
using UiTests.Helpers;
using UiTests.Tests;

namespace UiTests;

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
                await CodeTracerSessionRegistry.TerminateAllAsync();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to terminate CodeTracer sessions: {ex}");
            }
        }
    }
}
