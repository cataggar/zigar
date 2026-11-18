'use strict';

const SYM_DISPOSE = Symbol.dispose ?? Symbol.for('Symbol.dispose');
let lastDisposed = '';

function delay(ms, value) {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms));
}

class CjsResource {
  constructor(label) {
    this._label = label;
    this._done = false;
  }

  [SYM_DISPOSE]() {
    if (!this._done) {
      this._done = true;
      lastDisposed = `cjs:${this._label}`;
    }
  }
}

module.exports = {
  async mulAsync(a, b) {
    await delay(2);
    return a * b;
  },

  joinIterable(parts, sep) {
    return Array.from(parts).join(sep);
  },

  asyncCountUp(n) {
    return {
      async *[Symbol.asyncIterator]() {
        for (let i = 1; i <= n; i++) {
          await delay(1);
          yield i * 10;
        }
      },
    };
  },

  CjsResource,

  lastCjsDisposed() {
    return lastDisposed;
  },
};
