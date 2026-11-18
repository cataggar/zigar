// 1. Subsumed prefix overload deduplication
export declare function parseHexOrRadix(raw: string): number;
export declare function parseHexOrRadix(raw: string, radix?: number): number;

// 2. Smart semantic overload naming + unified comptime dispatchers
export declare class Buf {
  readonly byteLength: number;
  toHex(): string;
  static from(text: string, encoding?: "utf8" | "hex"): Buf;
  static from(bytes: Uint8Array): Buf;
  static from(items: readonly number[]): Buf;
}

export interface ReadOptions {
  encoding?: string;
}

export type ReadData = string | Uint8Array;

export declare function readFile(path: string, cb: (err: string | null, data: Uint8Array) => void): void;
export declare function readFile(path: string, encoding: "utf8", cb: (err: string | null, data: string) => void): void;
export declare function readFile(path: string, opts: ReadOptions, cb: (err: string | null, data: ReadData) => void): void;

export declare class MiniEmitter {
  readonly label: string;
  constructor();
  constructor(maxListeners: number);
  constructor(name: string, maxListeners: number);
  on(event: "data", listener: (chunk: string) => void): this;
  on(event: "error", listener: (err: string) => void): this;
  on(event: "open", listener: () => void): this;
  on(event: "close", listener: () => void): this;
  off(event: "data", listener: (chunk: string) => void): this;
  off(event: "open", listener: () => void): this;
  emitData(chunk: string): void;
  emitError(err: string): void;
  emitOpen(): void;
  emitClose(): void;
  clearAll(): void;
}

export declare function sumTupleOrTriple(pair: [number, number]): number;
export declare function sumTupleOrTriple(a: number, b: number, c: number): number;

export declare function pickArity(a: number, b?: number): string;
export declare function pickArity(a: number): number;

// 3. Variadic rest parameters (`...args: any[]` and typed `...nums: number[]`)
export declare function consoleFormat(prefix: string, ...args: any[]): string;
export declare function sumScaled(scale?: number, ...nums: number[]): number;

// 4. Callbacks (bare fn, type alias, callable interface, optional cb, error propagation) & HOF Callables
export type StringMapper = (item: string, index: number) => string;
export interface NumberPred {
  (val: number): boolean;
}
export interface CounterBox {
  count: number;
}

export declare function mapStrings(items: readonly string[], mapper: StringMapper): string[];
export declare function filterNumbers(nums: readonly number[], pred: NumberPred, onDone?: (keptCount: number) => void): number[];
export declare function deferTick(msg: string, cb: (payload: string) => void): () => void;
export declare function catchCallbackError(val: number, cb: (x: number) => number): string;
export declare function makePrefixer(prefix: string): (code: number) => string;
export declare function makeScaledBoxAdder(scale: number): (this: CounterBox, delta: number) => number;

// 5. Explicit `this: T` vs `this: void` parameters on standalone functions and callbacks
export declare class LiveCounter {
  count: number;
  constructor(initial: number);
}

export declare function incrementLiveCounter(this: LiveCounter, step: number): number;
export declare function detachedDouble(this: void, n: number): number;
export declare function invokeWithLiveCounterThis(
  target: LiveCounter,
  mult: number,
  cb: (this: LiveCounter, mult: number) => number,
): number;
export declare function invokeWithBoxThis(
  box: CounterBox,
  delta: number,
  cb: (this: CounterBox, delta: number) => number,
): number;

// 6. Type predicates (`x is T`, `asserts x is T`, `this is T`, `asserts this is T`, `asserts cond`)
export declare class AstNode {
  readonly kind: string;
  constructor(kind: string);
}

export declare class BinaryExpr extends AstNode {
  readonly op: string;
  readonly lhs: number;
  readonly rhs: number;
  constructor(op: string, lhs: number, rhs: number);
  eval(): number;
}

export declare function isBinaryExpr(node: AstNode): node is BinaryExpr;
export declare function assertBinaryExpr(node: AstNode): asserts node is BinaryExpr;
export declare function makeUnknownValue(kind: "str" | "num"): unknown;
export declare function isStringPayload(val: unknown): val is string;
export declare function assertPositiveFlag(ok: boolean, label?: string): asserts ok;

export declare class Channel {
  constructor(ready: boolean);
  isReady(): this is ReadyChannel;
  assertReady(): asserts this is ReadyChannel;
}

export declare class ReadyChannel extends Channel {
  readonly token: string;
  constructor(token: string);
  send(msg: string): string;
}

export declare function openChannel(ready: boolean, token: string): Channel;
