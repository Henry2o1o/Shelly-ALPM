using System.Net;
using System.Net.Sockets;

namespace Shelly.Utilities.Networking;

public static class OptimizedClient
{
    private static SocketsHttpHandler CreateHandler(
        long connectionLifetimeMinutes = 5,
        long connectionIdleTimeoutMinutes = 2,
        int maxConnectionsPerServer = 10,
        DecompressionMethods decompressionMethods = DecompressionMethods.All,
        bool allowAutoRedirect = true,
        int maxAutomaticRedirections = 20,
        long connectionTimeoutSeconds = 30,
        bool enableMultipleHttp2Connections = true,
        bool enableMultipleHttp3Connections = true,
        CancellationToken cancellationToken = default
    ) => new()
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(connectionLifetimeMinutes),
        PooledConnectionIdleTimeout = TimeSpan.FromMinutes(connectionIdleTimeoutMinutes),
        MaxConnectionsPerServer = maxConnectionsPerServer,
        AutomaticDecompression = decompressionMethods,
        AllowAutoRedirect = allowAutoRedirect,
        MaxAutomaticRedirections = maxAutomaticRedirections,
        ConnectTimeout = TimeSpan.FromSeconds(connectionTimeoutSeconds),
        EnableMultipleHttp2Connections = enableMultipleHttp2Connections,
        EnableMultipleHttp3Connections = enableMultipleHttp3Connections,
        ConnectCallback = async (context, connectToken) =>
        {
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(connectToken, cancellationToken);
            var entry = await Dns.GetHostEntryAsync(context.DnsEndPoint.Host, linkedCts.Token);

            var attempts = entry.AddressList.Select(async addr =>
            {
                var socket = new Socket(addr.AddressFamily, SocketType.Stream, ProtocolType.Tcp)
                {
                    NoDelay = true
                };
                try
                {
                    using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    timeoutCts.CancelAfter(TimeSpan.FromSeconds(3)); // fast per-address fallback
                    await socket.ConnectAsync(addr, context.DnsEndPoint.Port, timeoutCts.Token);
                    return socket;
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            }).ToList();

            var winner = await Task.WhenAny(attempts);
            var winningSocket = await winner;

            return new NetworkStream(winningSocket, ownsSocket: true);
        },
    };

    public static HttpClient CreateClient(long httpTimeoutSeconds = 30, long connectionLifetimeMinutes = 5,
        long connectionIdleTimeoutMinutes = 2, CancellationToken cancellationToken = default) =>
        new(
            CreateHandler(connectionLifetimeMinutes, connectionIdleTimeoutMinutes,
                cancellationToken: cancellationToken), true)
        {
            Timeout = TimeSpan.FromSeconds(httpTimeoutSeconds),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
            DefaultRequestVersion = HttpVersion.Version11,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
        };
}