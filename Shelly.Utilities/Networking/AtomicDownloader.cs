namespace Shelly.Utilities.Networking
{
    public static class AtomicDownloader
    {
        public static async Task DownloadAsync(string url, string filePath, long httpTimeoutSeconds = 30,
            long connectionLifetimeMinutes = 5, long connectionIdleTimeoutMinutes = 2,
            CancellationToken cancellationToken = default)
        {
            using var client = OptimizedClient.CreateClient(httpTimeoutSeconds, connectionLifetimeMinutes,
                connectionIdleTimeoutMinutes, cancellationToken);
        }
    }
}