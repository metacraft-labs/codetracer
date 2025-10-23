using System.Globalization;
using System.IO;
using Microsoft.Extensions.Logging;

namespace UiTests.Infrastructure;

internal sealed class EnvironmentParallelismProvider : IParallelismProvider
{
    private readonly ILogger<EnvironmentParallelismProvider> _logger;

    public EnvironmentParallelismProvider(ILogger<EnvironmentParallelismProvider> logger)
    {
        _logger = logger;
    }

    public int GetRecommendedParallelism()
    {
        try
        {
            var processorCount = Environment.ProcessorCount;
            var containerLimit = TryReadContainerQuota();
            if (containerLimit.HasValue)
            {
                var limited = Math.Max(1, Math.Min(processorCount, containerLimit.Value));
                if (limited != processorCount)
                {
                    _logger.LogInformation("Detected cgroup CPU quota limiting parallelism to {Parallelism} thread(s) (host advertised {ProcessorCount}).", limited, processorCount);
                }

                return limited;
            }

            return Math.Max(1, processorCount);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to derive CPU quota from the runtime environment. Falling back to Environment.ProcessorCount.");
            return Math.Max(1, Environment.ProcessorCount);
        }
    }

    private static int? TryReadContainerQuota()
    {
        if (OperatingSystem.IsLinux())
        {
            var cgroupV2Path = "/sys/fs/cgroup/cpu.max";
            var quota = ParseQuotaFile(cgroupV2Path, separator: ' ');
            if (quota.HasValue)
            {
                return quota;
            }

            var cfsQuotaPath = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us";
            var cfsPeriodPath = "/sys/fs/cgroup/cpu/cpu.cfs_period_us";
            if (File.Exists(cfsQuotaPath) && File.Exists(cfsPeriodPath))
            {
                var quotaText = File.ReadAllText(cfsQuotaPath).Trim();
                var periodText = File.ReadAllText(cfsPeriodPath).Trim();

                if (quotaText == "-1")
                {
                    return null;
                }

                if (long.TryParse(quotaText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var quotaValue) &&
                    long.TryParse(periodText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var periodValue) &&
                    quotaValue > 0 && periodValue > 0)
                {
                    var quotaCpu = (int)Math.Floor((double)quotaValue / periodValue);
                    return quotaCpu > 0 ? quotaCpu : 1;
                }
            }
        }

        return null;
    }

    private static int? ParseQuotaFile(string path, char separator)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        var content = File.ReadAllText(path).Trim();
        var parts = content.Split(separator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length < 2)
        {
            return null;
        }

        if (string.Equals(parts[0], "max", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (long.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var quotaValue) &&
            long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var periodValue) &&
            quotaValue > 0 && periodValue > 0)
        {
            var limit = (int)Math.Floor((double)quotaValue / periodValue);
            return limit > 0 ? limit : 1;
        }

        return null;
    }
}
