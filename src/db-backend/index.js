// index.js (ESM)
const worker = new Worker("./worker.js");

worker.onmessage = (e) => {
  console.log('FROM WORKER: ', e.data); // responses/events from the worker (Rust)
};

myWorker.onerror = (event) => {
  console.log("Something went wrong in the worker!");
};

// Example: send an "initialize" request (DAP)
const req = {
  seq: 1,
  type: 'request',
  command: 'initialize',
  arguments: { clientName: 'WebClient', linesStartAt1: true },
};

worker.postMessage(req);

console.log("Sending message", req)
