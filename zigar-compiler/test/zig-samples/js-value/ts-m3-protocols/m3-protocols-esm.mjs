const SYM_DISPOSE = Symbol.dispose ?? Symbol.for('Symbol.dispose');
const SYM_ASYNC_DISPOSE = Symbol.asyncDispose ?? Symbol.for('Symbol.asyncDispose');
const NODE_DISPOSE = Symbol.for('nodejs.dispose');
const NODE_ASYNC_DISPOSE = Symbol.for('nodejs.asyncDispose');

let genClosedCount = 0;
let asyncGenClosedCount = 0;
let asyncTouchCount = 0;
let disposeLog = [];

function delay(ms, value) {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms));
}

export function resetCounters() {
  genClosedCount = 0;
  asyncGenClosedCount = 0;
  asyncTouchCount = 0;
  disposeLog = [];
}

export function getGenClosedCount() {
  return genClosedCount;
}

export function getAsyncGenClosedCount() {
  return asyncGenClosedCount;
}

export function getAsyncTouchCount() {
  return asyncTouchCount;
}

export function getDisposeLog() {
  return disposeLog.slice();
}

export function sumIterable(items) {
  let total = 0;
  for (const x of items) {
    total += x;
  }
  return total;
}

export function rangeIter(start, count) {
  return {
    *[Symbol.iterator]() {
      for (let i = 0; i < count; i++) {
        yield start + i;
      }
    },
  };
}

export function* tokenGen(prefix) {
  let i = 0;
  try {
    while (true) {
      yield `${prefix}:${i++}`;
    }
  } finally {
    genClosedCount++;
  }
}

export class TokenCursor {
  constructor(items, shouldThrowOnDispose = false) {
    this._items = Array.from(items);
    this._shouldThrowOnce = Boolean(shouldThrowOnDispose);
    this._disposed = false;
  }

  *[Symbol.iterator]() {
    for (const item of this._items) {
      yield item;
    }
  }

  [SYM_DISPOSE]() {
    if (this._shouldThrowOnce) {
      this._shouldThrowOnce = false;
      throw new Error('sync-dispose-failed');
    }
    if (!this._disposed) {
      this._disposed = true;
      disposeLog.push(`cursor:${this._items.join('+')}`);
    }
  }
}

export class LegacySyncHandle {
  constructor(tag) {
    this._tag = tag;
    this._disposed = false;
  }

  [NODE_DISPOSE]() {
    if (!this._disposed) {
      this._disposed = true;
      disposeLog.push(`legacy-sync:${this._tag}`);
    }
  }
}

export function withDisposable(res, tag) {
  if (typeof res[SYM_DISPOSE] !== 'function' && typeof res[NODE_DISPOSE] !== 'function') {
    throw new TypeError('missing dispose method');
  }
  return `disposable:${tag}`;
}

export function sumConstrained(items) {
  return sumIterable(items);
}

export async function fetchDoubled(n) {
  await delay(2);
  return n * 2;
}

export async function fetchGreeting(name) {
  await delay(3);
  return `Hello, ${name}!`;
}

export async function touchAsyncCounter() {
  await delay(1);
  asyncTouchCount += 1;
}

export function nestedPromiseValue(seed) {
  return Promise.resolve(delay(2, seed + 100));
}

export async function aliasedPromise(n) {
  await delay(1);
  return n * 3;
}

export async function loadEntry(arg) {
  await delay(2);
  if (typeof arg === 'number') {
    return arg * 10;
  }
  return `entry:${arg}`;
}

export async function asyncIdentity(val) {
  await delay(1);
  return val;
}

export async function failAsync(code) {
  await delay(2);
  const err = new Error(`boom:${code}`);
  err.code = code;
  throw err;
}

export function streamChunks(prefix, count) {
  return {
    async *[Symbol.asyncIterator]() {
      for (let i = 0; i < count; i++) {
        await delay(1);
        yield `${prefix}:${i}`;
      }
    },
  };
}

export async function* infiniteAsyncCounter(start) {
  let cur = start;
  try {
    while (true) {
      await delay(1);
      yield cur++;
    }
  } finally {
    asyncGenClosedCount++;
  }
}

export class AsyncSession {
  constructor(id) {
    this._id = id;
    this._msgs = [];
    this._disposed = false;
  }

  async send(msg) {
    await delay(1);
    this._msgs.push(msg);
    return this._msgs.length;
  }

  async *[Symbol.asyncIterator]() {
    for (let i = 0; i < this._msgs.length; i++) {
      await delay(1);
      yield { seq: i + 1, text: `${this._id}:${this._msgs[i]}` };
    }
  }

  async [SYM_ASYNC_DISPOSE]() {
    await delay(2);
    if (!this._disposed) {
      this._disposed = true;
      disposeLog.push(`async-session:${this._id}:${this._msgs.length}`);
    }
  }
}

export class LegacyAsyncHandle {
  constructor(tag) {
    this._tag = tag;
    this._disposed = false;
  }

  async [NODE_ASYNC_DISPOSE]() {
    await delay(2);
    if (!this._disposed) {
      this._disposed = true;
      disposeLog.push(`legacy-async:${this._tag}`);
    }
  }
}

export function makeSyncOnlyDisposableForAsyncFallback(tag) {
  let disposed = false;
  return {
    [SYM_DISPOSE]() {
      if (!disposed) {
        disposed = true;
        disposeLog.push(`sync-fallback:${tag}`);
      }
    },
  };
}
