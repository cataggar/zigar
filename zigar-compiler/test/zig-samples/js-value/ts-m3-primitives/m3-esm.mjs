import { Buffer } from 'node:buffer';

export const SMALL_BIGINT = -99_999_000_111n;
export const HUGE_BIGINT = (1n << 100n) + 7n;
export const ULTRA_BIGINT = 999_999_999_999_999_999_999_999_999_999_999_999_999_999n;

export const UNIQUE_TOKEN = Symbol.for('zigar.m3.unique_token');
export let moduleTag = 'initial-tag';
export let moduleCount = 10;
export let gUndef = 'esm-seed-undef';
export let gNull = 'esm-seed-null';
export let gMaybe = null;
export let gUndefAlias = undefined;

export function mutateEsmBindings(nextTag, delta) {
  moduleTag = nextTag;
  moduleCount += delta;
}

let voidAcc = 0;

export default function defaultBanner(prefix, code = 200) {
  return `[${arguments.length}]${prefix}#${code}`;
}

export function recordVoid(delta) {
  voidAcc += delta;
}

export function getVoidAcc() {
  return voidAcc;
}

export function alwaysThrow(reason) {
  throw new TypeError(`never-error:${reason}`);
}

export function formatPrimitives(flag, score, id, label) {
  if (typeof flag !== 'boolean') throw new TypeError('expected boolean');
  if (typeof score !== 'number') throw new TypeError('expected number');
  if (typeof id !== 'bigint') throw new TypeError('expected bigint');
  if (typeof label !== 'string') throw new TypeError('expected string');
  return `${flag}|${score.toFixed(2)}|${id.toString()}|${label}`;
}

export function addHugeBigInt(lhs, delta) {
  if (typeof lhs !== 'bigint' || typeof delta !== 'bigint') {
    throw new TypeError('expected bigint operands');
  }
  return lhs + delta;
}

export function borrowJsString(input) {
  if (typeof input !== 'string') throw new TypeError('expected string');
  return `${input}🚀`;
}

export function checkUniqueSymbol(sym) {
  return typeof sym === 'symbol' && sym === UNIQUE_TOKEN;
}

export function roundtripIntrinsics(obj, anyVal, unkVal) {
  if (typeof obj !== 'object' || obj === null) throw new TypeError('expected non-null object');
  return [ obj, anyVal, unkVal ];
}

export function callWithDefaults(base, suffix = '!', repeat = 2) {
  return `${arguments.length}:${base}${String(suffix).repeat(repeat)}`;
}

export function classifyNullishArgs(nullArm, undefArm, bothArm) {
  const kindOf = (v) => (v === null ? 'null' : v === undefined ? 'undefined' : `str(${v})`);
  return `${kindOf(nullArm)}|${kindOf(undefArm)}|${kindOf(bothArm)}`;
}

export function produceInboundOptional(mode) {
  if (mode === 0) return null;
  if (mode === 1) return undefined;
  return 'present-value';
}

export function produceRawForNullable(mode) {
  if (mode === 0) return undefined;
  if (mode === 1) return null;
  return 42.5;
}

export function consumeRawFromNullable(val) {
  if (val === undefined) return 'is-undefined';
  if (val === null) return 'is-null';
  return `is-value:${val}`;
}

function tagJsVal(v) {
  if (v === null) return 'null';
  if (v === undefined) return 'undefined';
  return `${typeof v}:${String(v)}`;
}

export function inspectInterfaceNullish(p) {
  if (typeof p !== 'object' || p === null) throw new TypeError('expected object');
  if (!('reqNull' in p)) throw new TypeError('missing required property reqNull');
  if (!('reqUndef' in p)) throw new TypeError('missing required property reqUndef');
  if (p.reqNull === undefined) throw new TypeError('reqNull must never be undefined');
  if (p.reqUndef === null) throw new TypeError('reqUndef must never be null');

  const optNumPart = ('optNum' in p) ? `optNum=${tagJsVal(p.optNum)}` : 'no-optNum';
  const optNullPart = ('optNull' in p) ? `optNull=${tagJsVal(p.optNull)}` : 'no-optNull';
  let itemsPart = 'no-items';
  if ('items' in p) {
    if (!Array.isArray(p.items)) throw new TypeError('expected items array');
    itemsPart = `items=[${p.items.map(tagJsVal).join(',')}]`;
  }
  return `reqNull=${tagJsVal(p.reqNull)}|reqUndef=${tagJsVal(p.reqUndef)}|${optNumPart}|${optNullPart}|${itemsPart}`;
}

export function inspectInlineNullish(p) {
  if (typeof p !== 'object' || p === null) throw new TypeError('expected inline object');
  if (!('reqNull' in p)) throw new TypeError('missing inline reqNull');
  if (!('reqUndef' in p)) throw new TypeError('missing inline reqUndef');
  if (p.reqNull !== null && typeof p.reqNull !== 'number') {
    throw new TypeError(`unexpected inline reqNull: ${tagJsVal(p.reqNull)}`);
  }
  if (p.reqUndef !== undefined && typeof p.reqUndef !== 'number') {
    throw new TypeError(`unexpected inline reqUndef: ${tagJsVal(p.reqUndef)}`);
  }
  const hasOpt = 'optNum' in p;
  const hasCollisionProp = 'zigar_js' in p;
  if (hasCollisionProp) {
    return {
      outNull: null,
      outUndef: undefined,
      optTag: `hasOpt=${hasOpt}:zigar_js=${p.zigar_js}`,
    };
  }
  return {
    outNull: p.reqNull === null ? 'was-null' : `num:${p.reqNull}`,
    outUndef: p.reqUndef === undefined ? undefined : `num:${p.reqUndef}`,
  };
}

export function inspectNullishTuple(t) {
  if (!Array.isArray(t)) throw new TypeError('expected tuple array');
  if (t.length < 2) throw new TypeError(`tuple too short: ${t.length}`);
  if (!(0 in t)) throw new TypeError('tuple slot 0 must not be a sparse hole');
  if (t[0] === null) throw new TypeError('tuple[0] (number | undefined) must be undefined, got null');
  if (t[1] === undefined) throw new TypeError('tuple[1] (string | null) must be null, got undefined');
  for (let i = 2; i < t.length; i++) {
    if (t[i] === undefined) {
      throw new TypeError(`tuple rest[${i - 2}] (number | null) must be null, got undefined`);
    }
  }
  return [
    t[0] === undefined ? 77 : undefined,
    t[1] === null ? 'from-null' : null,
    ...t.slice(2).map((x) => (x === null ? 0 : null)),
  ];
}

export function inspectNullishSlices(strNulls, numUndefs, items) {
  if (!Array.isArray(strNulls) || !Array.isArray(numUndefs)) {
    throw new TypeError('expected genuine JS Arrays');
  }
  for (let i = 0; i < strNulls.length; i++) {
    if (strNulls[i] === undefined) {
      throw new TypeError(`strNulls[${i}] must be string or null, got undefined`);
    }
  }
  for (let i = 0; i < numUndefs.length; i++) {
    if (!(i in numUndefs)) throw new TypeError(`numUndefs[${i}] must not be sparse`);
    if (numUndefs[i] === null) {
      throw new TypeError(`numUndefs[${i}] must be number or undefined, got null`);
    }
  }
  let itemsDesc = `argc=${arguments.length}:omitted`;
  if (arguments.length >= 3) {
    if (!Array.isArray(items)) throw new TypeError('expected items array when passed');
    for (let i = 0; i < items.length; i++) {
      if (items[i] === undefined) {
        throw new TypeError(`items[${i}] must be string or null, got undefined`);
      }
    }
    itemsDesc = `argc=${arguments.length}:[${items.map(tagJsVal).join(',')}]`;
  }
  return `sn=[${strNulls.map(tagJsVal).join(',')}]|nu=[${numUndefs.map(tagJsVal).join(',')}]|${itemsDesc}`;
}

export function inspectRestUndef(prefix, ...args) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === null) throw new TypeError(`restUndef[${i}] must never be null`);
  }
  return `${prefix}:[${args.map(tagJsVal).join(',')}]`;
}

export function inspectRestNull(prefix, ...args) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === undefined) throw new TypeError(`restNull[${i}] must never be undefined`);
  }
  return `${prefix}:[${args.map(tagJsVal).join(',')}]`;
}

export function transformStringArray(items, extra) {
  if (!Array.isArray(items) || !Array.isArray(extra)) {
    throw new TypeError('expected genuine JS Arrays');
  }
  const sum = extra.reduce((acc, n) => acc + n, 0);
  return [ ...items.map((s) => s.toUpperCase()), `sum=${sum}` ];
}

export function flipFixedPair(pair) {
  if (!Array.isArray(pair) || pair.length !== 2) {
    throw new TypeError(`expected 2-tuple array, got len=${pair?.length}`);
  }
  return [ pair[0] + 0.5, !pair[1] ];
}

export function normalizeEndpoint(ep, omitPortOut) {
  if (!Array.isArray(ep)) throw new TypeError('expected endpoint array');
  const host = `${ep[0]}:${ep.length}`;
  if (omitPortOut) {
    return [ host ];
  }
  return [ host, ep[1] === undefined ? 443 : ep[1] + 1 ];
}

export function routeSummary(route) {
  if (!Array.isArray(route)) throw new TypeError('expected route array');
  const [ host, port, ...tags ] = route;
  return [ `${host}@${route.length}`, port === undefined ? 8080 : port, ...tags.map((t) => `#${t}`), 'ok' ];
}

export function evalLeadingFlags(input) {
  if (!Array.isArray(input) || input.length < 1) throw new TypeError('expected leading variadic array');
  const target = input[input.length - 1];
  const flags = input.slice(0, -1).map((f) => !f);
  return [ ...flags, `${target}:done` ];
}

export function evalMiddleSandwich(input) {
  if (!Array.isArray(input) || input.length < 2) throw new TypeError('expected middle variadic array');
  const head = input[0] * 2;
  const tail = !input[input.length - 1];
  const mid = input.slice(1, -1).map((s) => s.toUpperCase());
  return [ head, ...mid, tail ];
}

export function inspectGenericAliasNullish(p, box, ...rest) {
  if (nested.gMaybe !== null) {
    throw new TypeError(`expected nested.gMaybe === null, got ${tagJsVal(nested.gMaybe)}`);
  }
  if (nested.gUndefAlias !== undefined) {
    throw new TypeError(`expected nested.gUndefAlias === undefined, got ${tagJsVal(nested.gUndefAlias)}`);
  }
  if (!('reqMaybe' in p) || p.reqMaybe === undefined) {
    throw new TypeError(`expected reqMaybe null/string, got ${tagJsVal(p.reqMaybe)}`);
  }
  if (!('reqUndef' in p) || p.reqUndef === null) {
    throw new TypeError(`expected reqUndef undefined/string, got ${tagJsVal(p.reqUndef)}`);
  }
  const optMaybePart = ('optMaybe' in p) ? `optMaybe=${tagJsVal(p.optMaybe)}` : 'no-optMaybe';
  const optUndefPart = ('optUndef' in p) ? `optUndef=${tagJsVal(p.optUndef)}` : 'no-optUndef';
  if (!Array.isArray(p.maybeItems) || p.maybeItems.some((x) => x === undefined)) {
    throw new TypeError('maybeItems must contain string or null, never undefined');
  }
  if (!Array.isArray(p.pair) || p.pair.length !== 2 || p.pair[0] === undefined || p.pair[1] === null) {
    throw new TypeError(`invalid generic alias tuple: [${p.pair.map(tagJsVal).join(',')}]`);
  }
  if (!('val' in box) || box.val === undefined) {
    throw new TypeError(`expected box.val null/number, got ${tagJsVal(box.val)}`);
  }
  const boxOptPart = ('opt' in box) ? `boxOpt=${tagJsVal(box.opt)}` : 'no-boxOpt';
  if (rest.some((x) => x === null)) {
    throw new TypeError('OptList<number> rest must contain number or undefined, never null');
  }
  return [
    `reqMaybe=${tagJsVal(p.reqMaybe)}`,
    `reqUndef=${tagJsVal(p.reqUndef)}`,
    optMaybePart,
    optUndefPart,
    `items=[${p.maybeItems.map(tagJsVal).join(',')}]`,
    `pair=[${p.pair.map(tagJsVal).join(',')}]`,
    `boxVal=${tagJsVal(box.val)}`,
    boxOptPart,
    `rest=[${rest.map(tagJsVal).join(',')}]`,
  ].join('|');
}

export function malformedTupleReturn(kind) {
  if (kind === 0) return { notAnArray: true };
  if (kind === 1) return [];
  if (kind === 2) return [ 'allocated-host-string', 9000, 'allocated-tag-one', 99999 ];
  return [ 'ok', 80 ];
}

export function mutateBinaryInPlace(buf, u8, i32, f64, i64, ab, sab, dv) {
  if (!Buffer.isBuffer(buf)) throw new TypeError('expected Buffer');
  if (!(u8 instanceof Uint8Array)) throw new TypeError('expected Uint8Array');
  if (!(i32 instanceof Int32Array)) throw new TypeError('expected Int32Array');
  if (!(f64 instanceof Float64Array)) throw new TypeError('expected Float64Array');
  if (!(i64 instanceof BigInt64Array)) throw new TypeError('expected BigInt64Array');
  if (!(ab instanceof ArrayBuffer)) throw new TypeError('expected ArrayBuffer');
  if (!(sab instanceof SharedArrayBuffer)) throw new TypeError('expected SharedArrayBuffer');
  if (!(dv instanceof DataView)) throw new TypeError('expected DataView');

  buf[0] = (buf[0] + 10) & 0xff;
  u8[1] = 0xab;
  i32[0] = i32[0] * 3;
  f64[1] = f64[1] + 0.25;
  i64[0] = i64[0] - 1000n;
  new Uint8Array(ab)[2] = 0x77;
  Atomics.add(new Int32Array(sab), 0, 50);
  dv.setUint16(0, 0xbeef, true);

  return Buffer.from([ buf[0], u8[1], new Uint8Array(ab)[2], dv.getUint8(0), dv.getUint8(1) ]);
}

export const nested = {
  hits: 5,
  gUndef: 'nested-initial-undef',
  gNull: 'nested-initial-null',
  gMaybe: 100,
  gUndefAlias: 200,
  verifyNestedNullishGlobals() {
    if (!('gUndef' in nested) || !('gNull' in nested)) {
      throw new TypeError('missing nested global properties');
    }
    return `nested:${tagJsVal(nested.gUndef)}|${tagJsVal(nested.gNull)}`;
  },
  deep: {
    combine(a, b = 9) {
      nested.hits += 1;
      return `${a}:${b}:hits=${nested.hits}`;
    },
  },
};
