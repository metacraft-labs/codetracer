// omniscient-db-size / javascript / mid_length_compute
const crypto = require("crypto");

function fold(state, chunk) {
  const h = crypto.createHash("sha256");
  h.update(state);
  h.update(chunk);
  return h.digest();
}

let state = Buffer.from("seed");
let accum = 0;
const chunks = [];
for (let i = 0; i < 64; ++i) {
  const chunk = Buffer.alloc(64);
  for (let j = 0; j < 64; ++j) chunk[j] = (i + j) % 251;
  chunks.push(chunk);
}
for (let round = 0; round < 200; ++round) {
  for (const chunk of chunks) {
    state = fold(state, chunk);
    accum = (accum + state[0]) & 0xffff;
  }
}
console.log(accum, state.length);
