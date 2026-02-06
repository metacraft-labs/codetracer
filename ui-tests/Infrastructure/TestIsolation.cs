namespace UiTests.Infrastructure;

/// <summary>
/// Provides isolated configuration directories for tests to prevent
/// test interference through shared config files.
/// </summary>
public sealed class IsolatedConfigScope : IDisposable
{
    public string ConfigDirectory { get; }

    public IsolatedConfigScope(string testId)
    {
        // Create a unique temp directory for this test's config
        var basePath = Path.Combine(Path.GetTempPath(), "codetracer-test-config");
        Directory.CreateDirectory(basePath);

        // Use test ID + timestamp + random suffix for uniqueness
        var safeName = string.Join("_", testId.Split(Path.GetInvalidFileNameChars()));
        var uniqueName = $"{safeName}_{DateTime.Now:HHmmss}_{Guid.NewGuid():N}";
        ConfigDirectory = Path.Combine(basePath, uniqueName);

        Directory.CreateDirectory(ConfigDirectory);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(ConfigDirectory))
            {
                Directory.Delete(ConfigDirectory, recursive: true);
            }
        }
        catch
        {
            // Best effort cleanup - don't fail the test if cleanup fails
        }
    }
}
