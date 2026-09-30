// A JavaScript sample.
/* A block
   comment. */
import { readFile } from "fs/promises";

/**
 * JSDoc for a class.
 * @param {number} n
 */
export class Counter extends Base {
  #count = 0;
  constructor(start = 0) {
    super();
    this.#count = start;
  }
  get value() { return this.#count; }
  async load(path) {
    const text = await readFile(path, "utf8");
    return text.split(/\r?\n/g).filter((l) => l.length > 0);
  }
}

const greeting = `hello ${name.toUpperCase()} and ${1 + 2}`;
let hex = 0xff, bin = 0b101, big = 10n, flt = 1.5e-3;
const re = /[a-z]+\d*$/i;
if (hex >= 10 && !Number.isNaN(flt)) {
  console.log(greeting, re.test("abc1"), typeof big === "bigint");
}
export default function* gen() { yield* [1, 2]; }
