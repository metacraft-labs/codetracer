using System.Net;
using System.Net.Sockets;

namespace UiTestsPlayground.Helpers;

/// <summary>
/// Networking helpers for reserving local TCP ports when orchestrating multiple CodeTracer instances.
/// </summary>
internal static class NetworkUtilities
{
    /// <summary>
    /// Reserves a free TCP port on localhost and returns it. The listener is closed immediately after
    /// discovery, so callers should still prepare for the rare case where the port is claimed by another
    /// process before use.
    /// </summary>
    public static int GetFreeTcpPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
