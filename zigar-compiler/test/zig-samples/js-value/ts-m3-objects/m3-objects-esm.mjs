import CjsSocket from './m3-objects-cjs.cjs';
import DefaultSession from './m3-objects-def.mjs';

export function describeRequestOptions(opts, note) {
  const hasKeepAlive = 'keepAlive' in opts;
  const hasRetries = 'retries' in opts;
  const hasHeaders = 'headers' in opts;
  const portDesc = 'port' in opts ? String(opts.port) : 'omitted';
  const reasonDesc = note.reason === null ? 'null' : String(note.reason);
  return `${opts.host}:${portDesc}|ka=${hasKeepAlive ? opts.keepAlive : 'omitted'}|ret=${hasRetries ? opts.retries : 'omitted'}|hdr=${hasHeaders ? opts.headers.join(',') : 'omitted'}|${note.label}:${reasonDesc}`;
}

export function makeDefaultOptions() {
  return {
    host: '0.0.0.0',
    port: 3000,
    keepAlive: true,
    headers: [ 'x-one', 'x-two' ],
  };
}

export function sumLinkedNodes(head) {
  const ids = [];
  let sum = 0;
  let cur = head;
  while (cur) {
    ids.push(cur.id);
    sum += cur.value;
    cur = cur.next ?? null;
  }
  return `${ids.join('->')}=${sum}`;
}

export class BaseTransport {
  static SPEC_VERSION = 2;

  constructor(protocol) {
    this.protocol = protocol;
  }

  static supportedCount() {
    return 3;
  }

  ping() {
    return this.protocol === 'http:' || this.protocol === 'https:';
  }
}

let lastLogSink = 'none';
let currentEnv = 'production';

export class HttpClient extends BaseTransport {
  static defaultPort = 443;
  static version = '26.0.0';

  static set logSink(sink) {
    lastLogSink = String(sink);
  }

  static get env() {
    return currentEnv;
  }

  static set env(val) {
    currentEnv = val === null ? 'unset' : String(val);
  }

  constructor(baseUrl, timeout = 1000) {
    const proto = String(baseUrl).startsWith('https:') ? 'https:' : 'http:';
    super(proto);
    this.baseUrl = String(baseUrl);
    this.timeout = Number(timeout);
    this.mode = 'fast';
    this._endpoint = `${this.baseUrl}/`;
    this._authToken = '';
  }

  get endpoint() {
    return this._endpoint;
  }

  set endpoint(val) {
    if (typeof val === 'number') {
      this._endpoint = `${this.baseUrl}:${val}`;
    } else {
      this._endpoint = `${this.baseUrl}${val}`;
    }
  }

  set authToken(token) {
    this._authToken = String(token);
  }

  static createDefault() {
    return new HttpClient('https://default.zigar.dev', 1500);
  }

  request(path, opts) {
    const hostPart = opts ? `${opts.host}:${opts.port ?? HttpClient.defaultPort}` : 'default';
    return `${this.mode}|${this.timeout}|${this._endpoint}${path}|${hostPart}`;
  }
}

export function upcastTransport(client) {
  return client;
}

export function produceImpostorTransport() {
  return {
    protocol: 'https:',
    ping() {
      return true;
    },
  };
}

export function verifyClientAndState(client) {
  if (!(client instanceof HttpClient) || !(client instanceof BaseTransport)) {
    throw new TypeError('Expected real HttpClient extends BaseTransport instance');
  }
  return `sink=${lastLogSink}|env=${currentEnv}|tok=${client._authToken}`;
}

function CustomUrlCtor(input, base) {
  if (!(this instanceof CustomUrlCtor)) {
    throw new TypeError('CustomUrl must be invoked with new');
  }
  const u = base !== undefined ? new URL(input, base) : new URL(input);
  this.href = u.href;
  Object.defineProperty(this, 'origin', {
    value: u.origin,
    writable: false,
    enumerable: true,
  });
}

CustomUrlCtor.prototype.toJSON = function toJSON() {
  return this.href;
};

CustomUrlCtor.canParse = function canParse(input, base) {
  try {
    // eslint-disable-next-line no-new
    new URL(input, base);
    return true;
  } catch {
    return false;
  }
};

Object.defineProperty(CustomUrlCtor, 'schemeVersion', {
  get() {
    return 1;
  },
  enumerable: true,
});

export const CustomUrl = CustomUrlCtor;

export function produceImpostorCustomUrl() {
  return {
    href: 'https://fake.zigar.dev/',
    origin: 'https://fake.zigar.dev',
    toJSON() {
      return this.href;
    },
  };
}

export function produceImpostorSocket() {
  return {
    port: 80,
    ref() { return this; },
    unref() { return this; },
    isRefed() { return true; },
  };
}

export function verifySocketAndSession(sock, sess) {
  if (!(sock instanceof CjsSocket)) {
    throw new TypeError('Expected real CjsSocket instance');
  }
  if (!(sess instanceof DefaultSession)) {
    throw new TypeError('Expected real DefaultSession instance');
  }
  return `sock:${sock.port}:${sock.isRefed()}|sess:${sess.user}:${DefaultSession.activeCount}`;
}

let lastCursorGetterReads = 0;

export function makeCursor(items) {
  lastCursorGetterReads = 0;
  const copy = Array.from(items);
  let idx = 0;
  return {
    get position() {
      lastCursorGetterReads += 1;
      return idx;
    },
    next() {
      if (idx >= copy.length) return null;
      const v = copy[idx];
      idx += 1;
      return v;
    },
    reset() {
      idx = 0;
    },
  };
}

export function cursorPositionGetterReads() {
  return lastCursorGetterReads;
}

export function produceBadCursor(mode) {
  if (mode === 0) {
    // Missing required `next` and `reset` methods
    return { position: 0 };
  }
  if (mode === 1) {
    // `next` exists but is NOT a function
    return { position: 0, next: 'not-a-fn', reset() {} };
  }
  return [ 'array-not-cursor' ];
}

let lastCounterObj = null;

export function makeLiveCounter(initial) {
  let c = Number(initial);
  lastCounterObj = {
    get count() {
      return c;
    },
    set count(v) {
      c = typeof v === 'string' ? Number.parseInt(v, 10) : Number(v);
    },
  };
  return lastCounterObj;
}

export function readLastCounterValue() {
  return lastCounterObj ? lastCounterObj.count : -1;
}

export function produceArrayAsCounter() {
  return [ 1, 2, 3 ];
}

function FactoryCallable(arg) {
  if (new.target) {
    return new HttpClient(String(arg), 3200);
  }
  return `${FactoryCallable.tag}:${arg}`;
}
Object.defineProperty(FactoryCallable, 'tag', {
  value: 'v1-factory',
  writable: false,
  enumerable: true,
});

export function getCallableFactory() {
  return FactoryCallable;
}

export function produceBadCallableFactory() {
  return { tag: 'not-callable' };
}

export function Widget(name) {
  return {
    id: 7,
    render() {
      return `<widget:${name}>`;
    },
  };
}

export function FactoryConfig(host) {
  return { host: String(host), port: 9000 };
}

export function formatFactoryConfig(cfg) {
  return `${cfg.host}:${'port' in cfg ? cfg.port : 'default'}`;
}

export function echoStrBox(box) {
  return {
    value: `${box.value}!`,
    meta: box.meta ?? 'auto-meta',
    extra: box.extra + 1,
  };
}

export function makeSvc(topic, port) {
  return {
    topic: String(topic),
    port: Number(port),
    emit(event) {
      return `${topic}:${event}`.length;
    },
  };
}

export function produceBadSvc() {
  return { port: 8080, topic: 'missing-emit' };
}

export class StoreBase {
  constructor(initial) {
    this._val = initial;
  }

  getCurrent() {
    return this._val;
  }

  setCurrent(val) {
    this._val = val;
  }
}

export class NumberStore extends StoreBase {
  constructor(initial) {
    super(Number(initial));
  }

  step() {
    this._val += 1;
    return this._val;
  }
}

