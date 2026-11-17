import { EventEmitter, Stream } from './m3-heritage-base.mjs';
import $ from './m3-heritage-cjs.cjs';
import defaultCreate from './m3-heritage-def.mjs';

export { EventEmitter, Stream, $, defaultCreate };

let getterReads = 0;

export function closableGetterSideEffects() {
  return getterReads;
}

export function resetClosableGetterSideEffects() {
  getterReads = 0;
}

export class Readable extends Stream {
  #chunks = [ 'alpha', 'beta' ];

  constructor(hwm) {
    super();
    this.readableHighWaterMark = hwm;
  }

  read(size) {
    if (this.#chunks.length === 0) return null;
    const head = this.#chunks.shift();
    return size !== undefined ? `${head}:${size}` : head;
  }
}

export class Duplex extends Readable {
  #written = [];

  constructor(hwm) {
    super(hwm);
    this.isClosed = false;
  }

  write(chunk) {
    if (this.isClosed) return false;
    this.#written.push(chunk);
    return true;
  }

  close() {
    this.isClosed = true;
  }

  duplexSummary() {
    return `hwm=${this.readableHighWaterMark}|closed=${this.isClosed}|written=${this.#written.join(',')}`;
  }
}

export function inspectAsEmitter(ee) {
  return `ee:${ee instanceof EventEmitter}:${ee.listenerTotal}`;
}

export function inspectAsStream(st) {
  return st.pipe('sink');
}

export function inspectAsClosable(cl) {
  return `closable:${cl.isClosed}`;
}

export function makeMysteryEmitter(kind) {
  if (kind === 'duplex') {
    const d = new Duplex(64);
    d.on('data');
    return d;
  }
  if (kind === 'readable') {
    const r = new Readable(32);
    r.on('readable');
    return r;
  }
  const ee = new EventEmitter();
  let closedState = false;
  Object.defineProperty(ee, 'isClosed', {
    enumerable: true,
    configurable: true,
    get() {
      getterReads += 1;
      return closedState;
    },
  });
  ee.close = function close() {
    closedState = true;
  };
  return ee;
}

export function makeDiamondChannel(id, tag) {
  return {
    id,
    tag,
    status: 'open',
    ping() {
      return 204;
    },
    open(arg) {
      if (typeof arg === 'number') {
        return arg > 0;
      }
      return `opened:${arg}@${this.id}`;
    },
    query(arg) {
      if (typeof arg === 'number') {
        return arg * 10;
      }
      return `${this.tag}:${arg}`;
    },
  };
}

export function describeHostConfig(cfg) {
  const hasPort = Object.prototype.hasOwnProperty.call(cfg, 'port') && cfg.port !== undefined;
  return `${cfg.host}:${hasPort ? cfg.port : 'default'}`;
}

export function describeTlsConfig(cfg) {
  const hasAlpn = Object.prototype.hasOwnProperty.call(cfg, 'alpn') && cfg.alpn !== undefined;
  return `tls=${cfg.tls}|alpn=${hasAlpn ? cfg.alpn : 'none'}`;
}

export function describeCombinedConfig(cfg) {
  return `${describeHostConfig(cfg)}|${describeTlsConfig(cfg)}|w=${cfg.workers}`;
}

export function echoBrandPair(uid, port) {
  return `uid=${uid}|port=${port}`;
}

export function formatTaggedOutcome(outcome) {
  if (outcome.kind === 'ok') {
    return `[${outcome.requestId}]ok=${outcome.value}`;
  }
  return `[${outcome.requestId}]err=${outcome.message}`;
}

export function makeAdminSession(valid) {
  const r = new Readable(128);
  r.role = 'admin';
  r.audit = function audit(action) {
    return `audit:${this.role}:${action}`;
  };
  if (valid) {
    let closed = false;
    Object.defineProperty(r, 'isClosed', {
      enumerable: true,
      configurable: true,
      get() {
        getterReads += 1;
        return closed;
      },
    });
    r.close = function close() {
      closed = true;
    };
  }
  return r;
}

export function summarizeHeaderBag(bag) {
  return Object.keys(bag)
    .sort()
    .map((k) => `${k}=${bag[k]}`)
    .join('&');
}

export function makeDualTable() {
  const obj = { 0: 'zero', 1: 'one', mode: 'auto' };
  return obj;
}

export function makeDataAttrMap() {
  return { 'data-role': 'dialog' };
}

export function makeVerbTable() {
  return { GET: 200 };
}

export function makeInlineEnumDict() {
  return { tls: 'on' };
}

export function makeSymbolVault() {
  return {};
}

export function makeVaultSymbol(label) {
  return Symbol(label);
}

const dictLabels = new WeakMap();
const dictSlots = new WeakMap();

export function makeCollidingDict() {
  const d = Object.create({
    get(slot) {
      return Boolean(dictSlots.get(this)?.get(slot));
    },
    set(slot, active) {
      let m = dictSlots.get(this);
      if (!m) {
        m = new Map();
        dictSlots.set(this, m);
      }
      m.set(slot, Boolean(active));
    },
    init(label) {
      dictLabels.set(this, label);
    },
  });
  d.alpha = 10;
  return d;
}

export function collidingDictLabel(dict) {
  return dictLabels.get(dict) ?? 'unset';
}

export function makeMergedRegistry(name) {
  const store = Object.create({
    get name() {
      return name;
    },
    has(key) {
      return Object.prototype.hasOwnProperty.call(this, key) && key !== 'count';
    },
    clear() {
      let removed = 0;
      for (const k of Object.keys(this)) {
        if (k !== 'count') {
          delete this[k];
          removed += 1;
        }
      }
      this.count = 0;
      return removed;
    },
  });
  store.count = 1;
  store.seed = 7;
  return store;
}

export class RichService {
  static defaultTimeout = 1500;

  constructor(endpoint, timeoutMs = RichService.defaultTimeout) {
    this.endpoint = endpoint;
    this.timeoutMs = timeoutMs;
    this.connected = false;
  }

  connect() {
    this.connected = true;
    return this.connected;
  }

  mixinPing(tag) {
    return `${this.endpoint}[${this.timeoutMs}]:${tag}:${this.connected}`;
  }

  static fromOptions(opts) {
    return new RichService(opts.endpoint, opts.timeoutMs ?? RichService.defaultTimeout);
  }
}

export function formatMetric(name, value) {
  return `${formatMetric.prefix}:${name}=${value}`;
}
formatMetric.prefix = 'zigar';
formatMetric.reset = function reset() {
  formatMetric.prefix = 'zigar';
};

export function _(items) {
  return items.length;
}
_.VERSION = '4.17.21';
_.uniq = function uniq(items) {
  return Array.from(new Set(items));
};

export const LogLevel = {
  Info: 0,
  Warn: 1,
  Err: 2,
  defaultLevel: 1,
  parse(label) {
    if (label === 'err') return 2;
    if (label === 'warn') return 1;
    return 0;
  },
};

let telemetryEvents = [];
export const Telemetry = {
  serviceName: 'core',
  sampleRate: 0.5,
  record(metric) {
    telemetryEvents.push(`${this.serviceName}@${this.sampleRate}:${metric}`);
  },
  flush() {
    const n = telemetryEvents.length;
    telemetryEvents = [];
    return n;
  },
};

export function checkDefaultBridge(label) {
  return defaultCreate(label);
}
