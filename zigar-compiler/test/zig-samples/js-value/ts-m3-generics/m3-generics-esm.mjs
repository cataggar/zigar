export function identity(value) {
  return value;
}

export function wrapEnvelope(payload, meta) {
  return {
    payload,
    meta: meta !== undefined && meta !== null ? meta : { version: 1, tag: 'default' },
    ok: true,
  };
}

export function freezeTuple(items) {
  return Array.from(items, (x) => (typeof x === 'number' ? x * 2 : x));
}

export function selectWithFallback(candidates, fallback) {
  return Array.isArray(candidates) && candidates.length > 0 ? candidates[0] : fallback;
}

export function formatIdentified(item, prefix) {
  return `${prefix}#${item.id}`;
}

export function getField(obj, key) {
  return obj[key];
}

export function describeInput(arg) {
  if (typeof arg === 'string') {
    return `str:${arg}`;
  }
  return `item#${arg.id}`;
}

export class GenericStore {
  #map = new Map();

  constructor(label) {
    this.label = String(label);
  }

  get size() {
    return this.#map.size;
  }

  set(key, value) {
    this.#map.set(key, value);
  }

  get(key) {
    return this.#map.get(key);
  }

  snapshot(key) {
    if (!this.#map.has(key)) return null;
    return {
      payload: this.#map.get(key),
      meta: key,
      ok: true,
    };
  }

  transformGet(key, mapper) {
    if (!this.#map.has(key)) return null;
    return mapper(this.#map.get(key));
  }
}

export function applyUserPatch(base, patch) {
  const merged = { ...base };
  if (patch && typeof patch === 'object') {
    for (const [k, v] of Object.entries(patch)) {
      if (v !== undefined) {
        merged[k] = v;
      }
    }
  }
  if (merged.port === undefined || merged.port === null) {
    merged.port = 443;
  }
  return merged;
}

export function applyGenericPatch(base, patch) {
  return applyUserPatch(base, patch);
}

export function mergePickedAndOmitted(picked, omitted) {
  return { ...omitted, ...picked };
}

export function summarizeUserSummary(summary) {
  return {
    displayName: `${summary.displayName}#${summary.id}`,
    hostName: 'edge.internal',
  };
}

export function sumReadonlyCoords(coords) {
  let acc = 0;
  for (const n of coords) acc += Number(n);
  return acc;
}

export function totalVerbCounts(counts) {
  return Number(counts.GET || 0) + Number(counts.POST || 0) * 2 + Number(counts.DELETE || 0) * 3;
}

export function buildDynamicScores(prefix) {
  return {
    [`${prefix}:alpha`]: 11,
    [`${prefix}:beta`]: 29,
  };
}

export function requireText(val) {
  return `[${val}]`;
}

export function patchMeta(meta, patch) {
  const out = { ...meta };
  if (patch && typeof patch === 'object') {
    for (const [k, v] of Object.entries(patch)) {
      if (v !== undefined) out[k] = v;
    }
  }
  return out;
}

export function formatUnwrappedProfile(profile) {
  return `${profile.displayName}@${profile.hostName}:${profile.port ?? 80}`;
}

export const defaultEndpoint = Object.freeze({ host: 'api.zigar.dev', port: 9443 });

export function describeEndpointTuple(endpoint, args, owner) {
  return `${owner}->${endpoint.host}:${endpoint.port}(${args[0]})`;
}

export function inspectRequiredNullish(val) {
  const ok =
    'reqNull' in val && val.reqNull === null &&
    'optNull' in val && val.optNull === null &&
    'reqUndef' in val && val.reqUndef === undefined &&
    val.optStr === 'ok';
  return ok ? 'nul:ok' : `nul:bad:${JSON.stringify(val)}`;
}

export function inspectNullableVerbRecord(rec) {
  const ok =
    'GET' in rec && rec.GET === null &&
    rec.POST === 'live' &&
    'DELETE' in rec && rec.DELETE === null;
  return ok ? 'rec:ok' : `rec:bad:${JSON.stringify(rec)}`;
}

export const Direction = Object.freeze({
  Up: 0,
  Down: 1,
  0: 'Up',
  1: 'Down',
});

export function inspectNumericEnumRecord(rec) {
  if (!('0' in rec) || !('1' in rec) || 'up' in rec || 'down' in rec) {
    throw new TypeError(`Expected numeric enum keys "0" and "1", got: ${JSON.stringify(rec)}`);
  }
  return {
    0: `${rec[Direction.Up]}!`,
    1: `${rec[Direction.Down]}!`,
  };
}

export function flagsOf(obj) {
  return Object.fromEntries(Object.keys(obj).map((k) => [k, true]));
}

export function makeSyncScorer(scale) {
  return (input) => Number(input) * Number(scale);
}

export function makeGenScorer(prefix) {
  return (input) => `${prefix}:${input}`;
}

export function cacheGeneratorMethod(owner, name, sync, gen) {
  const wrapped = (...args) => sync.apply(owner, args);
  Object.defineProperty(wrapped, 'name', { value: String(name), configurable: true });
  wrapped.gen = gen;
  return wrapped;
}

export function attachStoreOverlay(store, extra) {
  return Object.assign(store, extra);
}



