export function parseHexOrRadix(raw, radix) {
  const r = arguments.length < 2 || radix === undefined ? 16 : radix;
  return Number.parseInt(raw, r);
}

export class Buf {
  #bytes;

  constructor(bytes) {
    this.#bytes = bytes;
  }

  get byteLength() {
    return this.#bytes.byteLength;
  }

  toHex() {
    return Array.from(this.#bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  }

  static from(input, encoding) {
    if (typeof input === 'string') {
      if (encoding === 'hex') {
        const out = new Uint8Array(input.length >> 1);
        for (let i = 0; i < out.length; i++) {
          out[i] = Number.parseInt(input.slice(i * 2, i * 2 + 2), 16);
        }
        return new Buf(out);
      }
      return new Buf(new TextEncoder().encode(input));
    }
    if (input instanceof Uint8Array) {
      return new Buf(new Uint8Array(input));
    }
    return new Buf(Uint8Array.from(input));
  }
}

const VIRTUAL_FILES = new Map([
  ['hello.txt', new Uint8Array([122, 105, 103, 45, 53, 48])], // "zig-50"
]);

export function readFile(path, arg2, arg3) {
  const bytes = VIRTUAL_FILES.get(path);
  if (typeof arg2 === 'function') {
    if (!bytes) {
      arg2(`ENOENT:${path}`, new Uint8Array(0));
      return;
    }
    arg2(null, new Uint8Array(bytes));
    return;
  }
  const encoding = typeof arg2 === 'string' ? arg2 : (arg2 && arg2.encoding ? arg2.encoding : null);
  const cb = arg3;
  if (!bytes) {
    cb(`ENOENT:${path}`, encoding === 'utf8' ? '' : new Uint8Array(0));
    return;
  }
  if (encoding === 'utf8') {
    cb(null, new TextDecoder().decode(bytes));
  } else {
    cb(null, new Uint8Array(bytes));
  }
}

export class MiniEmitter {
  #listeners = new Map();

  constructor(arg1, arg2) {
    if (arguments.length === 0) {
      this.label = 'default:10';
    } else if (typeof arg1 === 'number') {
      this.label = `anon:${arg1}`;
    } else {
      this.label = `${arg1}:${arg2}`;
    }
  }

  on(event, listener) {
    let list = this.#listeners.get(event);
    if (!list) {
      list = [];
      this.#listeners.set(event, list);
    }
    list.push(listener);
    return this;
  }

  emitData(chunk) {
    for (const fn of this.#listeners.get('data') || []) fn(chunk);
  }

  emitError(err) {
    for (const fn of this.#listeners.get('error') || []) fn(err);
  }

  emitOpen() {
    for (const fn of this.#listeners.get('open') || []) fn();
  }

  emitClose() {
    for (const fn of this.#listeners.get('close') || []) fn();
  }

  clearAll() {
    this.#listeners.clear();
  }

  off(event, listener) {
    const list = this.#listeners.get(event);
    if (list) {
      const idx = list.indexOf(listener);
      if (idx !== -1) list.splice(idx, 1);
    }
    return this;
  }
}

export function sumTupleOrTriple(a, b, c) {
  if (Array.isArray(a)) return a[0] + a[1];
  return a + b + c;
}

export function pickArity(a, b) {
  return b === undefined ? a * 10 : `opt2:${a},${b}`;
}

export function consoleFormat(prefix, ...args) {
  const formatted = args.map((v) => `${typeof v}:${String(v)}`).join(',');
  return `${prefix}[${args.length}]=${formatted}`;
}

export function sumScaled(scale, ...nums) {
  const factor = scale === undefined ? 1 : scale;
  let acc = 0;
  for (const n of nums) acc += n;
  return acc * factor;
}

export function mapStrings(items, mapper) {
  return items.map((item, index) => mapper(item, index));
}

export function filterNumbers(nums, pred, onDone) {
  const out = [];
  for (const n of nums) {
    if (pred(n)) out.push(n);
  }
  if (onDone !== undefined) {
    onDone(out.length);
  }
  return out;
}

export function deferTick(msg, cb) {
  return () => {
    cb(`tick:${msg}`);
  };
}

export function catchCallbackError(val, cb) {
  try {
    return `ok:${cb(val)}`;
  } catch (err) {
    return `caught:${err && err.message ? err.message : String(err)}`;
  }
}

export function makePrefixer(prefix) {
  return (code) => `${prefix}#${code}`;
}

export function makeScaledBoxAdder(scale) {
  return function (delta) {
    return this.count + delta * scale;
  };
}

export class LiveCounter {
  constructor(initial) {
    this.count = initial;
  }
}

export function incrementLiveCounter(step) {
  if (!(this instanceof LiveCounter)) {
    throw new TypeError('incrementLiveCounter requires LiveCounter `this`');
  }
  this.count += step;
  return this.count;
}

export function detachedDouble(n) {
  if (this !== undefined) {
    throw new TypeError('detachedDouble requires `this === undefined`');
  }
  return n * 2;
}

export function invokeWithLiveCounterThis(target, mult, cb) {
  return cb.call(target, mult);
}

export function invokeWithBoxThis(box, delta, cb) {
  return cb.call(box, delta);
}

export class AstNode {
  constructor(kind) {
    this.kind = kind;
  }
}

export class BinaryExpr extends AstNode {
  constructor(op, lhs, rhs) {
    super('binary');
    this.op = op;
    this.lhs = lhs;
    this.rhs = rhs;
  }

  eval() {
    return this.op === '+' ? this.lhs + this.rhs : this.lhs * this.rhs;
  }
}

export function isBinaryExpr(node) {
  return node instanceof BinaryExpr;
}

export function assertBinaryExpr(node) {
  if (!(node instanceof BinaryExpr)) {
    throw new TypeError(`Expected BinaryExpr, got ${node ? node.kind : 'null'}`);
  }
}

export function makeUnknownValue(kind) {
  if (kind === 'str') return 'narrowed-hello';
  return 99;
}

export function isStringPayload(val) {
  return typeof val === 'string';
}

export function assertPositiveFlag(ok, label) {
  if (!ok) {
    throw new RangeError(`Flag failed:${label ?? 'unnamed'}`);
  }
}

export class Channel {
  #ready;

  constructor(ready) {
    this.#ready = Boolean(ready);
  }

  isReady() {
    return this instanceof ReadyChannel && this.#ready;
  }

  assertReady() {
    if (!(this instanceof ReadyChannel) || !this.#ready) {
      throw new TypeError('Channel is not ReadyChannel');
    }
  }
}

export class ReadyChannel extends Channel {
  constructor(token) {
    super(true);
    this.token = token;
  }

  send(msg) {
    return `[${this.token}]>${msg}`;
  }
}

export function openChannel(ready, token) {
  return ready ? new ReadyChannel(token) : new Channel(false);
}

export function endOrBind(a, b) {
  if (typeof a === 'number' && typeof b === 'string') {
    return `bind:${b}:${a}`;
  }
  if (typeof a === 'function' || a === undefined) {
    if (typeof a === 'function') a();
    return 'end:empty';
  }
  if (typeof b === 'function') b();
  return `end:${typeof a}:${typeof a === 'object' && a !== null ? JSON.stringify(a) : String(a)}`;
}

export function acceptNestedPayload(payload) {
  return `nested:${typeof payload.data}:${String(payload.data)}`;
}

