// worker.js (ES module)
import init, {
  test,
  wasm_start
} from './pkg/db_backend.js';


// Point init at the .wasm file so paths work from inside the worker
const ready = init(new URL('./pkg/db_backend_bg.wasm', import.meta.url));

const req = {
  seq: 1,
  type: 'request',
  command: 'initialize',
  arguments: { clientName: 'WebClient', linesStartAt1: true },
};

(async () => {
  await ready;   // ⬅️ crucial
  // wasm_start() is already called inside init() via __wbindgen_start.
  // Call your exports only after init completes:
  test();
  // window.postMessage(req);
})();
