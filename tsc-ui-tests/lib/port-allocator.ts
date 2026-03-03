import * as net from "node:net";

/**
 * Allocates a free TCP port by binding to port 0 and reading the assigned port.
 * The listener is closed immediately after reading the port number.
 */
export function getFreeTcpPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address() as net.AddressInfo;
      const port = addr.port;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

/**
 * Allocates multiple unique free TCP ports.
 */
export async function getFreeTcpPorts(count: number): Promise<number[]> {
  const ports: number[] = [];
  for (let i = 0; i < ports.length || ports.length < count; i++) {
    const port = await getFreeTcpPort();
    if (!ports.includes(port)) {
      ports.push(port);
    }
  }
  return ports;
}
