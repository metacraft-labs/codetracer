using Microsoft.Extensions.Logging;
using UiTests.Configuration;

namespace UiTests.Infrastructure;

internal interface IStabilityArtifactManager
{
    void PrepareArtifacts(StabilitySettings stabilitySettings);
}

internal sealed class StabilityArtifactManager : IStabilityArtifactManager
{
    private readonly ILogger<StabilityArtifactManager> _logger;

    public StabilityArtifactManager(ILogger<StabilityArtifactManager> logger)
    {
        _logger = logger;
    }

    public void PrepareArtifacts(StabilitySettings stabilitySettings)
    {
        if (stabilitySettings is null)
        {
            return;
        }

        var root = Path.GetFullPath(stabilitySettings.Artifacts.Root);
        Directory.CreateDirectory(root);

        if (stabilitySettings.Artifacts.ClearLogs)
        {
            TryDelete(Path.Combine(root, "logs"), "stability logs");
        }

        if (stabilitySettings.Artifacts.ClearArtifacts)
        {
            TryDelete(Path.Combine(root, "media"), "stability media");
        }
    }

    private void TryDelete(string path, string description)
    {
        try
        {
            if (!Directory.Exists(path))
            {
                return;
            }

            Directory.Delete(path, recursive: true);
            _logger.LogInformation("Cleared {Description} at {Path}.", description, path);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to clear {Description} at {Path}.", description, path);
        }
    }
}
