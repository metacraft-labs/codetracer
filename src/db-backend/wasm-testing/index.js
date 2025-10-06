// index.js (ESM)

const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });

console.log("Initialized the worker");

let workerPromise =
  new Promise((resolve, reject) => {
    worker.onmessage = (e) => {
      console.assert(e.data == "ready");
      if (e.data == "ready") {
        worker.onmessage = (e) => {
          console.log("I JUST RECEIVED FROM THE WORKER");
          console.log(e);
        }
        resolve();
      } else {
        reject();
      };
      console.log('FROM WORKER: ', e.data); // responses/events from the worker (Rust)
    }
  })

worker.onerror = (event) => {
  console.log("Something went wrong in the worker!");
  console.log(event);
};

// Example: send an "initialize" request (DAP)
const req = {
  seq: 1,
  type: 'request',
  command: 'initialize',
  arguments: { clientName: 'WebClient', linesStartAt1: true },
};


let blq = () => {
  console.log(":(((((");
  console.log("Sending message", req);
  worker.postMessage(req);
}

(async () => { await workerPromise; blq() })()
