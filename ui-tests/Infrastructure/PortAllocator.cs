using System.Net;
using System.Net.Sockets;

namespace UiTests.Infrastructure;

internal interface IPortAllocator
{
    int GetFreeTcpPort();
}

internal sealed class PortAllocator : IPortAllocator
{
    public int GetFreeTcpPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
