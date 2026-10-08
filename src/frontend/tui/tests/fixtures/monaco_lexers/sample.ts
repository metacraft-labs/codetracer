// A TypeScript sample.
import type { Readable } from "stream";

/* A block comment
   over two lines. */
export interface Named {
  readonly name: string;
  age?: number;
}

enum Color { Red = "RED", Green = "GREEN" }

type Pair<T> = [T, T];

abstract class Animal implements Named {
  constructor(public readonly name: string, private legs: number = 4) {}
  abstract speak(): void;
}

function pick<T extends object, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key];
}

const pair: Pair<number> = [1, 2];
const pattern = /^(\w+)\s*=\s*(.*)$/;
const message = `color: ${Color.Red} ${pair[0] as number}`;
let maybe: string | undefined = undefined;
const n = maybe?.length ?? 0;
console.log(message, pattern.source, n satisfies number);
