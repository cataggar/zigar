export type AsyncBox<T> = Promise<T>;

export declare function resetCounters(): void;
export declare function getGenClosedCount(): number;
export declare function getAsyncGenClosedCount(): number;
export declare function getAsyncTouchCount(): number;
export declare function getDisposeLog(): string[];

export declare function sumIterable(items: Iterable<number>): number;
export declare function rangeIter(start: number, count: number): Iterable<number>;
export declare function tokenGen(prefix: string): Generator<string, void, unknown>;

export declare class TokenCursor implements Iterable<string>, Disposable {
  constructor(items: readonly string[], shouldThrowOnDispose?: boolean);
  [Symbol.iterator](): IterableIterator<string>;
  [Symbol.dispose](): void;
}

export declare class LegacySyncHandle {
  constructor(tag: string);
  [Symbol.for("nodejs.dispose")](): void;
}

export declare function withDisposable<T extends Disposable>(res: T, tag: string): string;
export declare function sumConstrained<T extends Iterable<number>>(items: T): number;

export declare function fetchDoubled(n: number): Promise<number>;
export declare function fetchGreeting(name: string): Promise<string>;
export declare function touchAsyncCounter(): Promise<void>;
export declare function nestedPromiseValue(seed: number): Promise<Promise<number>>;
export declare function aliasedPromise(n: number): AsyncBox<number>;

export declare function loadEntry(id: number): Promise<number>;
export declare function loadEntry(key: string): Promise<string>;

export declare function asyncIdentity<T>(val: T): Promise<T>;
export declare function failAsync(code: string): Promise<number>;

export declare function streamChunks(prefix: string, count: number): AsyncIterable<string>;
export declare function infiniteAsyncCounter(start: number): AsyncGenerator<number, void, unknown>;

export interface SessionEvent {
  seq: number;
  text: string;
}

export declare class AsyncSession implements AsyncIterable<SessionEvent>, AsyncDisposable {
  constructor(id: string);
  send(msg: string): Promise<number>;
  [Symbol.asyncIterator](): AsyncIterableIterator<SessionEvent>;
  [Symbol.asyncDispose](): Promise<void>;
}

export declare class LegacyAsyncHandle {
  constructor(tag: string);
  [Symbol.for("nodejs.asyncDispose")](): Promise<void>;
}

export declare function makeSyncOnlyDisposableForAsyncFallback(tag: string): AsyncDisposable;
