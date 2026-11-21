// relay.mjs — serves a built web-core page over HTTP and relays its
// WebSocket to a replay-server child, one child per socket.
//
// Usage: node relay.mjs <built-dir> <replay-server> [port]
//
// The browser front-end reaches its engine over a socket; a replay-server
// speaks DAP over stdio with `Content-Length` framing. This process is the
// part between them and nothing else: it frames each WebSocket text message
// onto the child's stdin and sends each frame the child writes back as one
// text message. It does not read, reorder or answer any message.
//
// Prints `RELAY listening <port>` once the server is up.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';

const [dir, replayServer, portArg] = process.argv.slice(2);
const root = path.resolve(dir);
const require = createRequire(path.join(process.env.CT_REPO || process.cwd(), 'package.json'));
const { WebSocketServer } = require('ws');

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm' };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) {
    res.writeHead(404); res.end(); return;
  }
  res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});

const wss = new WebSocketServer({ server, path: '/dap' });
wss.on('connection', (ws) => {
  const child = spawn(replayServer, ['dap-server', '--stdio'], { stdio: ['pipe', 'pipe', 'inherit'] });
  let buf = Buffer.alloc(0);
  child.stdout.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      const sep = buf.indexOf('\r\n\r\n');
      if (sep < 0) return;
      const m = /Content-Length:\s*(\d+)/i.exec(buf.subarray(0, sep).toString());
      if (!m) { console.error('relay: a frame without Content-Length'); ws.close(); return; }
      const n = Number(m[1]);
      if (buf.length < sep + 4 + n) return;
      ws.send(buf.subarray(sep + 4, sep + 4 + n).toString('utf8'));
      buf = buf.subarray(sep + 4 + n);
    }
  });
  child.on('exit', () => ws.close());
  ws.on('message', (data) => {
    const body = Buffer.from(String(data), 'utf8');
    child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    child.stdin.write(body);
  });
  ws.on('close', () => child.kill());
});

server.listen(Number(portArg || 0), '127.0.0.1', () => {
  console.log(`RELAY listening ${server.address().port}`);
});
