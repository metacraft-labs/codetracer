// omniscient-db-size / javascript / io_heavy
const fs = require("fs");
const os = require("os");
const path = require("path");

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "ct-bench-io-"));
const sizes = [];
for (let i = 0; i < 64; ++i) {
  const p = path.join(scratch, `chunk_${i.toString().padStart(2, "0")}.bin`);
  fs.writeFileSync(p, Buffer.from("abcdefgh".repeat(i + 1), "utf8"));
  sizes.push(fs.readFileSync(p).length);
}
fs.rmSync(scratch, { recursive: true });
console.log(sizes.reduce((a, b) => a + b, 0));
