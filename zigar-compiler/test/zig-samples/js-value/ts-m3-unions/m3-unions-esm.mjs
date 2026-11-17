import { Buffer } from 'node:buffer';
import MiniChannel from './m3-unions-cjs.cjs';

export const HttpStatus = {
  Ok: 200,
  200: 'Ok',
  Created: 201,
  201: 'Created',
  SuccessAlias: 200,
  NotFound: 404,
  404: 'NotFound',
};

export const LargeOffset = {
  Zero: 0,
  0: 'Zero',
  FiveBillion: 5_000_000_000,
  5000000000: 'FiveBillion',
};

export const MixedCode = {
  Auto: 'auto',
  Zero: 0,
  0: 'Zero',
  One: 1,
  1: 'One',
};

export const RuntimeFlags = {
  Read: 4,
  Write: 8,
};

export const OpType = {
  Add: 'add',
  Reset: 'reset',
};

export function stepStatus(status, level, big) {
  const nextStatus = status === 200 ? 201 : 404;
  const nextLevel = level === 'info' ? 'warn' : 'info';
  const nextBig = big === 0 ? 5_000_000_000 : 0;
  return [ nextStatus, nextLevel, nextBig ];
}

export function badStatusReturn(mode) {
  if (mode === 0) return 999;
  if (mode === 1) return 200.5;
  if (mode === 2) return '200';
  return 'THIS_STRING_IS_WAY_TOO_LONG_FOR_ANY_ENUM_MEMBER_FAST_REJECT';
}

export function echoMixedAndClosed(mixed, enc, ord, step, big, scalar) {
  const scalarDesc = typeof scalar === 'bigint' ? `${scalar}n` : JSON.stringify(scalar);
  return `${mixed}|${enc}|${ord}|${step}|${big}n|${scalarDesc}`;
}

export function badBigChoiceWrapReturn() {
  return (1n << 64n) + 10n;
}

export function badMixedWrapReturn() {
  return (1n << 64n) + 1n;
}

export function badBigDiscWrapReturn() {
  return { k: (1n << 64n) + 1n, v: 'wrapped-mod-2^64' };
}

export function echoStrOrBoolPair(v) {
  return typeof v === 'string' ? true : 'was-bool';
}

export function combineRuntimeFlags(a, b) {
  return a | b;
}

export function inspectOpenLiterals(mime, port) {
  const nextMime = mime === 'application/json' ? 'image/webp' : 'text/plain';
  const nextPort = port === 443 ? 8080 : 80;
  return [ nextMime, nextPort ];
}

export function inspectTemplates(hook, ver, route) {
  if (hook !== 'onOpen' && hook !== 'onClose' && hook !== 'onError') {
    throw new Error(`bad hook: ${hook}`);
  }
  if (!/^https?:\/\/.+\/api\/-?\d+$/.test(route)) {
    throw new Error(`bad route: ${route}`);
  }
  return ver === 'v26.1.0' ? 'v26.2.0' : 'v1.0.0';
}

export function badSemVerReturn(mode) {
  if (mode === 0) return 'v1.2';
  if (mode === 1) return 'v1.2.three';
  return 12345;
}

export function processAuditEvent(ev) {
  if (ev.kind === 'created') {
    return { traceId: `${ev.traceId}:ack`, kind: 'patched', id: ev.id, rev: 7 };
  }
  if (ev.kind === 'updated' || ev.kind === 'patched') {
    return { traceId: `${ev.traceId}:del`, kind: 'deleted' };
  }
  return { traceId: `${ev.traceId}:new`, kind: 'created', id: ev.soft ? 'soft-id' : 'hard-id' };
}

export function badAuditEventReturn(mode) {
  if (mode === 0) {
    // Matches discriminant `kind === "created"`, but `id` is wrong type -> must NOT fall through!
    return { traceId: 't-err', kind: 'created', id: 999 };
  }
  if (mode === 1) {
    return { traceId: 't-unknown', kind: 'archived' };
  }
  return [ 'not-an-object' ];
}

export function processOutcomeAndCmd(out, cmd) {
  const outPart = out.ok
    ? `ok:${out.value}`
    : `err:${out.code}:${out.detail === null ? 'null' : out.detail === undefined ? 'undef' : out.detail}`;
  const cmdPart = cmd.op === 'add' ? `add:${cmd.amount}` : 'reset';
  return `${outPart}|${cmdPart}`;
}

export function produceHetero(mode) {
  switch (mode) {
    case 0: return [ 'only-one' ];
    case 1: return [ 'two-items', 42 ];
    case 2: return [ 'a', 'b', 'c' ];
    case 3: return Buffer.from([ 10, 20, 30 ]);
    case 4: return new Uint8Array([ 99, 88 ]);
    case 5: return new MiniChannel('alpha');
    case 6: return 'v3.4.5';
    case 7: return 'plain-text';
    case 8: return { host: 'zigar.dev' };
    case 9: return 123.5;
    default: return true;
  }
}

export function produceImpostorChannel() {
  return { label: 'impostor-not-minichannel' };
}

export function describeHetero(payload) {
  if (Array.isArray(payload)) return `arr:${payload.length}:${payload.join(',')}`;
  if (Buffer.isBuffer(payload)) return `buf:${payload.length}:${payload[0]}`;
  if (payload instanceof Uint8Array) return `u8:${payload.length}:${payload[0]}`;
  if (payload instanceof MiniChannel) return `chan:${payload.ping()}`;
  if (typeof payload === 'object' && payload !== null && 'label' in payload && !('host' in payload)) {
    return `chan:pong:${payload.label}`;
  }
  if (typeof payload === 'object' && payload !== null) {
    return `host:${payload.host}:${'port' in payload ? payload.port : 'omitted'}`;
  }
  return `${typeof payload}:${payload}`;
}

export function transformJson(val) {
  if (val === null) return [ 'was-null', 1, false ];
  if (typeof val === 'object' && !Array.isArray(val)) {
    return {
      seenKeys: Object.keys(val).sort().join(','),
      nestedNull: null,
      items: [ val.title ?? 'none', 99 ],
    };
  }
  return val;
}

export function unwrapEnvelope(env) {
  if (env.tag === 'val') {
    const hasKey = Object.prototype.hasOwnProperty.call(env, 'item');
    const kind = env.item === undefined ? 'undefined' : env.item === null ? 'null' : `num:${env.item}`;
    return [
      `val:${hasKey}:${kind}`,
      env.item === undefined ? { tag: 'val', item: null } : { tag: 'empty', reason: null },
    ];
  }
  const rKind = env.reason === null ? 'null' : env.reason === undefined ? 'undefined' : `str:${env.reason}`;
  return [ `empty:${rKind}`, { tag: 'val', item: 'recovered' } ];
}
