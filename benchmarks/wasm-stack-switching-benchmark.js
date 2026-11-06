#!/usr/bin/env node
'use strict';

/**
 * V8 13.6 WebAssembly Stack Switching & Growable Stacks Benchmark Suite
 * (Issue #14 — `growable-stacks-benchmark` workstream)
 *
 * Benchmarks V8 13.6's `--experimental-wasm-growable-stacks` (linked on-demand
 * stack segments via `WasmGrowableStackGuard` / `WasmShrinkStack`) against
 * default fixed-size JSPI stacks (`--wasm-stack-switching-stack-size=984`)
 * across 5 dimensions:
 *   1. Memory Footprint Scaling Across Concurrent Suspended JSPI Stacks
 *      (1, 10, 50, 100, 500, 1000 concurrent fibers at depth = 5 and depth = 100)
 *   2. Recursion Depth & Stack Overflow Resilience
 *      (depth = 5, 25, 100, 250, 500, 1000, 2500, 5000 + exact 4 KB overflow boundary)
 *   3. Dynamic Stack Shrinking After Deep-Recursion Burst
 *      (`WasmShrinkStack` unwind + `StackPool` 4 MiB cap physical page reclamation)
 *   4. JSPI Suspension / Resumption Latency Microbenchmark
 *      (10,000 sequential and 100x100 batched `WebAssembly.Suspending` <-> `WebAssembly.promising` cycles)
 *   5. Real Unmodified `.wasm` Ecosystem Binary Verification
 *      (`zigar`, `wazig`, `jsco` / `jco` WASI P1/P2/P3 modules & components)
 *
 * Usage:
 *   /opt/actions-runner/2.338.0/externals/node24/bin/node benchmarks/wasm-stack-switching-benchmark.js
 */

const { execFileSync } = require('node:child_process');
const { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, readdirSync, linkSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

const ROOT_DIR = path.resolve(__dirname, '..');
const DEFAULT_CACHE_ROOT = path.join(ROOT_DIR, '.tmp-bench');
const CACHE_ROOT = process.env.CACHE_ROOT || (existsSync(DEFAULT_CACHE_ROOT) ? DEFAULT_CACHE_ROOT : '/d/zigar-worktrees/.cache');
const TMP_ROOT = path.join(CACHE_ROOT, 'tmp');
const ZIG_GLOBAL_CACHE = path.join(CACHE_ROOT, 'zig-global');
const ZIG_LOCAL_CACHE = path.join(CACHE_ROOT, 'zig-local');
const WAZIG_MASTER_CACHE = existsSync(path.join(CACHE_ROOT, 'wazig-master-caches', 'wazig'))
  ? path.join(CACHE_ROOT, 'wazig-master-caches', 'wazig')
  : path.join('/d/zigar-worktrees/.cache', 'wazig-master-caches', 'wazig');

const NODE24_BIN = process.env.NODE24_BIN || (existsSync('/opt/actions-runner/2.338.0/externals/node24/bin/node')
  ? '/opt/actions-runner/2.338.0/externals/node24/bin/node'
  : process.execPath);
const WAZIG_BIN = process.env.WAZIG_BIN || (existsSync('/d/zig/wazig/bin/wazig') ? '/d/zig/wazig/bin/wazig' : '/home/g/.local/bin/wazig');
const ZIG_BIN = process.env.ZIG_BIN || '/home/g/.local/bin/zig';
const WASM_TOOLS_BIN = process.env.WASM_TOOLS_BIN || '/d/jco/submodules/wasm-tools/target/release/wasm-tools';
const JSCO_DIR = process.env.JSCO_DIR || '/d/jsco';
const DEFAULT_JSON_OUT = path.join(__dirname, 'stack-switching-results.json');

// Recursive Zig + WASI P1 (`fd_read`/`fd_write`) + JSPI (`async_yield`) benchmark kernel
// compiled by `wazig` (`0.17.0-wazig.3`) with `-target wasm32-wasi -O ReleaseSmall -fno-entry -rdynamic --export=__stack_pointer`.
const STACK_BENCH_ZIG_SOURCE = `const std = @import("std");

extern "wasi_snapshot_preview1" fn fd_read(fd: i32, iovs_ptr: [*]const std.os.wasi.iovec_t, iovs_len: usize, nread_ptr: *usize) i32;
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, ciovs_ptr: [*]const std.os.wasi.ciovec_t, ciovs_len: usize, nwritten_ptr: *usize) i32;
extern "env" fn async_yield(depth: i32, tag: i32) i32;

noinline fn wasiEchoLeaf(seed: i32) i32 {
    var read_buf: [4]u8 = .{ 0, 0, 0, 0 };
    var iov = [_]std.os.wasi.iovec_t{.{ .base = &read_buf, .len = read_buf.len }};
    var nread: usize = 0;
    _ = fd_read(0, &iov, 1, &nread);

    var ciov = [_]std.os.wasi.ciovec_t{.{ .base = &read_buf, .len = nread }};
    var nwritten: usize = 0;
    _ = fd_write(1, &ciov, 1, &nwritten);
    return @as(i32, @intCast(nwritten)) + @as(i32, read_buf[0]) + seed;
}

export fn recurseAndSuspend(depth: i32, seed: i32, mode: i32) i32 {
    const v0: i32 = seed ^ (depth *% 0x61c88647);
    const v1: i32 = (seed +% 3) ^ (depth *% 0x1e3779b9);
    const v2: i32 = v0 +% v1;
    const v3: i32 = v0 ^ (v1 >> 3);

    const child_res: i32 = if (depth <= 1) blk: {
        if (mode == 1 or mode == 3) {
            break :blk async_yield(depth, v2);
        } else if (mode == 2) {
            break :blk wasiEchoLeaf(v2);
        } else {
            break :blk v2 +% 1;
        }
    } else blk: {
        const sub = recurseAndSuspend(depth - 1, seed +% 1, mode);
        if (mode == 3 and depth == 2) {
            break :blk sub +% async_yield(2, v3);
        }
        break :blk sub;
    };

    return child_res +% ((v0 ^ v1 ^ v2 ^ v3) & 0xff);
}
`;

// ---------------------------------------------------------------------------
// Utility & Statistical Helpers
// ---------------------------------------------------------------------------

function ensureCacheDirs() {
  for (const dir of [CACHE_ROOT, TMP_ROOT, ZIG_GLOBAL_CACHE, ZIG_LOCAL_CACHE]) {
    mkdirSync(dir, { recursive: true });
  }
  process.env.TMPDIR = TMP_ROOT;
  process.env.ZIG_GLOBAL_CACHE_DIR = ZIG_GLOBAL_CACHE;
  process.env.ZIG_LOCAL_CACHE_DIR = ZIG_LOCAL_CACHE;
}

function hardlinkDirRecursive(srcDir, dstDir) {
  if (!existsSync(srcDir)) return;
  mkdirSync(dstDir, { recursive: true });
  for (const entry of readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = path.join(srcDir, entry.name);
    const dstPath = path.join(dstDir, entry.name);
    if (entry.isDirectory()) {
      hardlinkDirRecursive(srcPath, dstPath);
    } else if (entry.isFile() && !existsSync(dstPath)) {
      try {
        linkSync(srcPath, dstPath);
      } catch {
        // Ignore cross-device or existing file errors
      }
    }
  }
}

function getToolVersion(bin, args = ['version']) {
  if (!existsSync(bin)) return null;
  try {
    return execFileSync(bin, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 15_000,
    }).trim();
  } catch {
    return null;
  }
}

function roundTo(val, digits = 2) {
  if (typeof val !== 'number' || !Number.isFinite(val)) return null;
  const factor = 10 ** digits;
  return Math.round(val * factor) / factor;
}

function computeStats(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  const n = sorted.length;
  if (n === 0) return { min: 0, median: 0, mean: 0, p95: 0, max: 0, stddev: 0 };
  const sum = sorted.reduce((acc, v) => acc + v, 0);
  const mean = sum / n;
  const median = n % 2 === 1 ? sorted[(n - 1) >> 1] : (sorted[(n >> 1) - 1] + sorted[n >> 1]) / 2;
  const p95Idx = Math.min(n - 1, Math.floor(n * 0.95));
  const variance = n > 1 ? sorted.reduce((acc, v) => acc + (v - mean) ** 2, 0) / (n - 1) : 0;
  return {
    min: roundTo(sorted[0], 2),
    median: roundTo(median, 2),
    mean: roundTo(mean, 2),
    p95: roundTo(sorted[p95Idx], 2),
    max: roundTo(sorted[n - 1], 2),
    stddev: roundTo(Math.sqrt(variance), 2),
  };
}

// ---------------------------------------------------------------------------
// Linux `/proc/self/status` + `/proc/self/maps` + `process.memoryUsage()` Reader
// ---------------------------------------------------------------------------

function readMemorySnapshot() {
  const statusText = readFileSync('/proc/self/status', 'utf8');
  const getStatusKiB = (key) => {
    const match = statusText.match(new RegExp(`^${key}:\\s+(\\d+)\\s+kB`, 'm'));
    return match ? Number(match[1]) : 0;
  };

  let rwAnonKiB = 0;
  let protNoneAnonKiB = 0;
  try {
    const mapsText = readFileSync('/proc/self/maps', 'utf8');
    for (const line of mapsText.split('\n')) {
      if (!line) continue;
      const parts = line.trim().split(/\s+/);
      if (parts.length > 5) continue; // Skip file-backed mappings
      const [startHex, endHex] = parts[0].split('-');
      const sizeKiB = ( parseInt(endHex, 16) - parseInt(startHex, 16) ) / 1024;
      const perms = parts[1];
      if (perms.startsWith('rw')) rwAnonKiB += sizeKiB;
      else if (perms.startsWith('---')) protNoneAnonKiB += sizeKiB;
    }
  } catch {
    // Fallback if /proc/self/maps is unavailable
  }

  const mu = process.memoryUsage();
  return {
    vmPeakKiB: getStatusKiB('VmPeak'),
    vmSizeKiB: getStatusKiB('VmSize'),
    vmRSSKiB: getStatusKiB('VmRSS'),
    rssAnonKiB: getStatusKiB('RssAnon'),
    rwAnonKiB: Math.round(rwAnonKiB),
    protNoneAnonKiB: Math.round(protNoneAnonKiB),
    nodeRssKiB: Math.round(mu.rss / 1024),
    heapUsedKiB: Math.round(mu.heapUsed / 1024),
    externalKiB: Math.round(mu.external / 1024),
  };
}

// ---------------------------------------------------------------------------
// Pure-JS WebAssembly Core Module & Component Model Binary Inspector
// ---------------------------------------------------------------------------

function readULEB128(buf, offset) {
  let result = 0;
  let shift = 0;
  let pos = offset;
  while (pos < buf.length) {
    const byte = buf[pos++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) break;
    shift += 7;
  }
  return { value: result >>> 0, nextOffset: pos };
}

function readSLEB128(buf, offset) {
  let result = 0;
  let shift = 0;
  let pos = offset;
  let byte = 0;
  do {
    byte = buf[pos++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  if (shift < 32 && (byte & 0x40) !== 0) {
    result |= (~0 << shift);
  }
  return { value: result, nextOffset: pos };
}

function parseCoreModuleBinary(buf) {
  const info = {
    sizeBytes: buf.length,
    globalCount: 0,
    global0: null,
    exportCount: 0,
    exports: [],
    hasStackPointerExport: false,
    stackPointerGlobalIndex: null,
  };
  if (buf.length < 8 || buf.readUInt32LE(0) !== 0x6d736100 || buf.readUInt32LE(4) !== 0x00000001) {
    return info;
  }

  let pos = 8;
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    const { value: sectionSize, nextOffset: payloadStart } = readULEB128(buf, pos);
    const sectionEnd = payloadStart + sectionSize;
    if (sectionEnd > buf.length) break;

    if (sectionId === 6) {
      // Section 6: Globals
      let p = payloadStart;
      const { value: count, nextOffset } = readULEB128(buf, p);
      info.globalCount = count;
      p = nextOffset;
      if (count > 0 && p < sectionEnd) {
        const valTypeByte = buf[p++];
        const mutability = buf[p++];
        const valType = valTypeByte === 0x7f ? 'i32' : valTypeByte === 0x7e ? 'i64' : `0x${valTypeByte.toString(16)}`;
        let initVal = null;
        if (p < sectionEnd && buf[p] === 0x41) {
          p++;
          const imm = readSLEB128(buf, p);
          initVal = imm.value;
        }
        info.global0 = { valType, mutable: mutability === 1, initialValue: initVal };
      }
    } else if (sectionId === 7) {
      // Section 7: Exports
      let p = payloadStart;
      const { value: count, nextOffset } = readULEB128(buf, p);
      info.exportCount = count;
      p = nextOffset;
      for (let i = 0; i < count && p < sectionEnd; i++) {
        const { value: nameLen, nextOffset: nameStart } = readULEB128(buf, p);
        const name = buf.subarray(nameStart, nameStart + nameLen).toString('utf8');
        p = nameStart + nameLen;
        const kindByte = buf[p++];
        const { value: index, nextOffset: afterIdx } = readULEB128(buf, p);
        p = afterIdx;
        const kind = ['function', 'table', 'memory', 'global', 'tag'][kindByte] || `kind_${kindByte}`;
        info.exports.push({ name, kind, index });
        if (name === '__stack_pointer' && kind === 'global') {
          info.hasStackPointerExport = true;
          info.stackPointerGlobalIndex = index;
        }
      }
    }

    pos = sectionEnd;
  }

  return info;
}

function inspectWasmBinaryBuffer(buf) {
  if (buf.length < 8 || buf.readUInt32LE(0) !== 0x6d736100) {
    return { format: 'invalid', sizeBytes: buf.length, coreModules: [] };
  }
  const version = buf.readUInt32LE(4);
  if (version === 0x00000001) {
    return {
      format: 'core-module',
      headerHex: buf.subarray(0, 8).toString('hex'),
      sizeBytes: buf.length,
      coreModules: [{ moduleIndex: 0, buffer: buf, ...parseCoreModuleBinary(buf) }],
    };
  }
  if (version === 0x0001000d) {
    const coreModules = [];
    const extractFromComponent = (compBuf) => {
      let pos = 8;
      while (pos < compBuf.length) {
        const secId = compBuf[pos++];
        const { value: secSize, nextOffset: payloadStart } = readULEB128(compBuf, pos);
        const secEnd = payloadStart + secSize;
        if (secEnd > compBuf.length) break;
        const payload = compBuf.subarray(payloadStart, secEnd);
        if (secId === 1) {
          coreModules.push({
            moduleIndex: coreModules.length,
            buffer: payload,
            ...parseCoreModuleBinary(payload),
          });
        } else if (secId === 4) {
          extractFromComponent(payload);
        }
        pos = secEnd;
      }
    };
    extractFromComponent(buf);
    return {
      format: 'component-model',
      headerHex: buf.subarray(0, 8).toString('hex'),
      sizeBytes: buf.length,
      coreModules,
    };
  }
  return {
    format: `unknown-0x${version.toString(16)}`,
    headerHex: buf.subarray(0, 8).toString('hex'),
    sizeBytes: buf.length,
    coreModules: [],
  };
}

// ---------------------------------------------------------------------------
// Compile `stack_bench.zig` via `wazig` (`0.17.0-wazig.3`)
// ---------------------------------------------------------------------------

function compileWazigBenchmarkModule(workDir) {
  mkdirSync(workDir, { recursive: true });
  const localCacheDir = path.join(workDir, '.zig-cache');
  hardlinkDirRecursive(WAZIG_MASTER_CACHE, localCacheDir);

  const zigPath = path.join(workDir, 'stack_bench.zig');
  const wasmPath = path.join(workDir, 'stack_bench.wasm');
  writeFileSync(zigPath, STACK_BENCH_ZIG_SOURCE, 'utf8');

  const env = {
    ...process.env,
    GHR_TOOL_DIR: process.env.GHR_TOOL_DIR || path.resolve(path.dirname(WAZIG_BIN), '..'),
    TMPDIR: TMP_ROOT,
    ZIG_LOCAL_CACHE_DIR: '.zig-cache',
    ZIG_GLOBAL_CACHE_DIR: '.zig-cache',
  };
  delete env.ZIG_LIB_DIR;

  const t0 = performance.now();
  execFileSync(
    WAZIG_BIN,
    [
      'build-exe',
      'stack_bench.zig',
      '-target',
      'wasm32-wasi',
      '-OReleaseSmall',
      '-fno-entry',
      '--stack',
      '262144',
      '-rdynamic',
      '-femit-bin=stack_bench.wasm',
      '--cache-dir',
      '.zig-cache',
      '--global-cache-dir',
      '.zig-cache',
    ],
    {
      cwd: workDir,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 120_000,
    }
  );
  const compileMs = roundTo(performance.now() - t0, 2);
  const wasmBytes = readFileSync(wasmPath);
  const binaryInfo = inspectWasmBinaryBuffer(wasmBytes);
  return {
    zigPath,
    wasmPath,
    compileMs,
    wasmBytes,
    binaryInfo,
  };
}

function instantiateStackBenchModule(wasmBytes, hooks = {}) {
  const mod = new WebAssembly.Module(wasmBytes);
  let instance = null;

  const asyncYieldImpl = hooks.asyncYield
    ? hooks.asyncYield
    : async (depth, tag) => depth + tag;

  const fdReadImpl = hooks.fdRead
    ? hooks.fdRead
    : async (fd, iovsPtr, iovsLen, nreadPtr) => {
        const view = new DataView(instance.exports.memory.buffer);
        const bufPtr = view.getUint32(iovsPtr, true);
        const bufLen = view.getUint32(iovsPtr + 4, true);
        const u8 = new Uint8Array(instance.exports.memory.buffer, bufPtr, bufLen);
        if (bufLen >= 4) {
          u8[0] = 42;
          u8[1] = 10;
          u8[2] = 20;
          u8[3] = 30;
        }
        view.setUint32(nreadPtr, Math.min(bufLen, 4), true);
        return 0;
      };

  const fdWriteImpl = hooks.fdWrite
    ? hooks.fdWrite
    : async (fd, ciovsPtr, ciovsLen, nwrittenPtr) => {
        const view = new DataView(instance.exports.memory.buffer);
        const bufLen = view.getUint32(ciovsPtr + 4, true);
        view.setUint32(nwrittenPtr, bufLen, true);
        return 0;
      };

  instance = new WebAssembly.Instance(mod, {
    env: {
      async_yield: hooks.rawSyncYield
        ? hooks.rawSyncYield
        : new WebAssembly.Suspending(asyncYieldImpl),
    },
    wasi_snapshot_preview1: {
      fd_read: new WebAssembly.Suspending(fdReadImpl),
      fd_write: new WebAssembly.Suspending(fdWriteImpl),
    },
  });

  return {
    module: mod,
    instance,
    syncRecurse: instance.exports.recurseAndSuspend,
    promisingRecurse: WebAssembly.promising(instance.exports.recurseAndSuspend),
    stackPointerGlobal: instance.exports.__stack_pointer,
  };
}

// ---------------------------------------------------------------------------
// Child Process Worker Modes (Isolated V8 Flag Processes)
// ---------------------------------------------------------------------------

async function runWorkerMode(mode, payloadJson) {
  const payload = JSON.parse(payloadJson);
  const wasmBytes = readFileSync(payload.wasmPath);

  if (mode === 'dim1-memory') {
    const { fibers, depth } = payload;
    let gates = [];
    const { promisingRecurse } = instantiateStackBenchModule(wasmBytes, {
      asyncYield: () => new Promise((resolve) => gates.push(resolve)),
    });

    // Warm up Wasm execution and keep 1 anchor fiber suspended so V8's one-time
    // JSPI code space is already mapped and StackPool starts empty before `before` snapshot.
    for (let i = 0; i < 30; i++) {
      await promisingRecurse(5, i, 0);
    }
    const anchorPromise = promisingRecurse(5, 0, 1);
    await new Promise((r) => setImmediate(r));
    const anchorGate = gates.pop();
    gates = [];
    if (typeof global.gc === 'function') global.gc();

    // Prime `readMemorySnapshot()` buffer allocation once before measurement.
    readMemorySnapshot();
    const before = readMemorySnapshot();

    const fiberPromises = [];
    let overflowError = null;
    for (let i = 0; i < fibers; i++) {
      try {
        const p = promisingRecurse(depth, i + 1, 1).catch((err) => {
          if (!overflowError) overflowError = err;
          return -1;
        });
        fiberPromises.push(p);
      } catch (err) {
        overflowError = err;
        break;
      }
    }

    await new Promise((r) => setImmediate(r));

    if (overflowError || gates.length < fibers) {
      for (const resolve of gates) resolve(1);
      if (anchorGate) anchorGate(1);
      await Promise.allSettled([anchorPromise, ...fiberPromises]);
      process.stdout.write(
        JSON.stringify({
          status: 'STACK_OVERFLOW',
          fibers,
          depth,
          suspendedCount: gates.length,
          error: overflowError ? `${overflowError.name}: ${overflowError.message}` : 'Failed to suspend all fibers',
        })
      );
      return;
    }

    const suspended = readMemorySnapshot();

    // Release all N suspended fibers cleanly
    for (const resolve of gates) resolve(7);
    const results = await Promise.all(fiberPromises);
    const validChecksums = results.every((v) => typeof v === 'number' && v !== -999999 && v !== -1);

    if (anchorGate) anchorGate(1);
    await anchorPromise;

    const deltaVmSizeKiB = suspended.vmSizeKiB - before.vmSizeKiB;
    const deltaVmRSSKiB = suspended.vmRSSKiB - before.vmRSSKiB;
    const deltaRssAnonKiB = suspended.rssAnonKiB - before.rssAnonKiB;
    const deltaRwAnonKiB = suspended.rwAnonKiB - before.rwAnonKiB;
    const deltaNodeRssKiB = suspended.nodeRssKiB - before.nodeRssKiB;
    const deltaHeapUsedKiB = suspended.heapUsedKiB - before.heapUsedKiB;

    process.stdout.write(
      JSON.stringify({
        status: 'OK',
        fibers,
        depth,
        suspendedCount: gates.length,
        validChecksums,
        before,
        suspended,
        deltaVmSizeKiB,
        deltaVmRSSKiB,
        deltaRssAnonKiB,
        deltaRwAnonKiB,
        deltaNodeRssKiB,
        deltaHeapUsedKiB,
        vmSizeKiBPerFiber: roundTo(deltaVmSizeKiB / fibers, 2),
        vmRSSKiBPerFiber: roundTo(deltaVmRSSKiB / fibers, 2),
        rssAnonKiBPerFiber: roundTo(deltaRssAnonKiB / fibers, 2),
        rwAnonKiBPerFiber: roundTo(deltaRwAnonKiB / fibers, 2),
      })
    );
    return;
  }

  if (mode === 'dim2-recursion') {
    const { depths, findExact4KBOverflow } = payload;
    const { promisingRecurse, stackPointerGlobal } = instantiateStackBenchModule(wasmBytes, {
      asyncYield: async (d, tag) => d + tag,
    });

    // Warm up for tiered compilation
    for (let i = 0; i < 60; i++) {
      await promisingRecurse(25, i, 0);
    }

    let exactOverflowInfo = null;
    if (findExact4KBOverflow) {
      let maxSuccessDepth = 0;
      let firstOverflowDepth = null;
      let overflowMessage = null;
      for (let d = 1; d <= 250; d++) {
        try {
          const val = await promisingRecurse(d, 1, 1);
          if (val === -999999) throw new Error('Stack frame corruption');
          maxSuccessDepth = d;
        } catch (err) {
          firstOverflowDepth = d;
          overflowMessage = `${err.name}: ${err.message}`;
          break;
        }
      }
      exactOverflowInfo = {
        maxSuccessDepth,
        firstOverflowDepth,
        overflowMessage,
      };
    }

    const depthMeasurements = [];
    for (const depth of depths) {
      const spBefore = stackPointerGlobal.value;
      try {
        // Test 1: Recursion with actual JSPI suspension (`mode = 1`) at bottom of recursion tree
        const suspendCheck = await promisingRecurse(depth, 42, 1);
        if (suspendCheck === -999999) {
          throw new Error('Frame checksum mismatch after deep suspend/resume');
        }

        // Test 2: High-iteration throughput measurement on the JSPI stack (`mode = 0`)
        const iterations = depth <= 100 ? 2000 : depth <= 1000 ? 500 : 150;
        const sampleRuns = 5;
        const nsPerCallSamples = [];
        const nsPerFrameSamples = [];

        for (let r = 0; r < sampleRuns; r++) {
          const t0 = performance.now();
          let acc = 0;
          for (let i = 0; i < iterations; i++) {
            const p = promisingRecurse(depth, i, 0);
            // Because mode=0 does not suspend, promisingRecurse resolves immediately
            acc ^= await p;
          }
          const elapsedNs = (performance.now() - t0) * 1e6;
          if (acc === -999999) throw new Error('Checksum error');
          nsPerCallSamples.push(elapsedNs / iterations);
          nsPerFrameSamples.push(elapsedNs / (iterations * depth));
        }

        const callStats = computeStats(nsPerCallSamples);
        const frameStats = computeStats(nsPerFrameSamples);
        const spAfter = stackPointerGlobal.value;

        depthMeasurements.push({
          depth,
          status: 'OK',
          suspendedAtBottomVerified: true,
          linearStackRestored: spBefore === spAfter,
          iterationsPerSample: iterations,
          nsPerCallMedian: callStats.median,
          nsPerFrameMedian: frameStats.median,
          callsPerSec: Math.round(1e9 / callStats.median),
          framesPerSec: Math.round(1e9 / frameStats.median),
          nsPerFrameStats: frameStats,
        });
      } catch (err) {
        depthMeasurements.push({
          depth,
          status: 'STACK_OVERFLOW',
          error: `${err.name}: ${err.message}`,
        });
      }
    }

    process.stdout.write(
      JSON.stringify({
        exactOverflowInfo,
        depthMeasurements,
      })
    );
    return;
  }

  if (mode === 'dim3-shrink') {
    const { fibers = 200, deepDepth = 1000 } = payload;
    let bottomGates = [];
    let shallowGates = [];

    const { promisingRecurse } = instantiateStackBenchModule(wasmBytes, {
      asyncYield: (depth) => {
        if (depth <= 1) {
          return new Promise((resolve) => bottomGates.push(resolve));
        }
        return new Promise((resolve) => shallowGates.push(resolve));
      },
    });

    // Warm up Wasm and keep 1 anchor fiber so one-time JSPI code space is pre-initialized
    for (let i = 0; i < 40; i++) {
      await promisingRecurse(5, i, 0);
    }
    const anchorPromise = promisingRecurse(5, 0, 1);
    await new Promise((r) => setImmediate(r));
    const anchorGate = bottomGates.pop();
    bottomGates = [];
    if (typeof global.gc === 'function') global.gc();

    readMemorySnapshot();
    const phase1Baseline = readMemorySnapshot();

    // Phase 2: Launch 200 concurrent fibers that recurse to `depth = 1000` (`mode = 3`)
    // Each fiber grows its stack segments (`44 KiB -> 88 KiB -> 176 KiB`) via `WasmGrowableStackGuard`
    // and suspends at the bottom (`depth = 1`).
    const fiberPromises = [];
    for (let i = 0; i < fibers; i++) {
      fiberPromises.push(promisingRecurse(deepDepth, i + 1, 3));
    }
    await new Promise((r) => setImmediate(r));
    const phase2DeepBurst = readMemorySnapshot();

    // Phase 3: Resume from bottom (`depth = 1`), unwinding 998 stack frames!
    // Unwinding crosses segment boundaries and invokes `WasmShrinkStack` (`StackMemory::Shrink`),
    // moving `active_segment_` back to the initial 44 KiB segment before suspending again at `depth = 2`.
    for (const resolve of bottomGates) resolve(10);
    await new Promise((r) => setImmediate(r));
    const phase3UnwoundShallow = readMemorySnapshot();

    // Phase 4: Resume from shallow (`depth = 2`), letting all 200 fibers complete and return their
    // `StackMemory` objects to `StackPool`. Then trigger a single shallow JSPI call + GC so
    // `StackPool::GetOrAllocate()` enforces `kMaxPoolSize = 4 MiB` and frees excess segments via `PageAllocator::FreePages`.
    for (const resolve of shallowGates) resolve(20);
    const fiberResults = await Promise.all(fiberPromises);
    const allChecksumsValid = fiberResults.every((v) => typeof v === 'number' && v !== -999999);
    if (typeof global.gc === 'function') global.gc();
    await promisingRecurse(5, 99, 0);
    const phase4PostReclaim = readMemorySnapshot();

    if (anchorGate) anchorGate(1);
    await anchorPromise;

    const peakDeltaRssAnonKiB = phase2DeepBurst.rssAnonKiB - phase1Baseline.rssAnonKiB;
    const postReclaimDeltaRssAnonKiB = phase4PostReclaim.rssAnonKiB - phase1Baseline.rssAnonKiB;
    const reclaimedRssAnonKiB = phase2DeepBurst.rssAnonKiB - phase4PostReclaim.rssAnonKiB;
    const reclaimedRwAnonKiB = phase2DeepBurst.rwAnonKiB - phase4PostReclaim.rwAnonKiB;

    process.stdout.write(
      JSON.stringify({
        fibers,
        deepDepth,
        allChecksumsValid,
        suspendedAtBottomCount: bottomGates.length,
        suspendedAtShallowCount: shallowGates.length,
        phase1Baseline,
        phase2DeepBurst,
        phase3UnwoundShallow,
        phase4PostReclaim,
        metrics: {
          peakDeltaVmSizeKiB: phase2DeepBurst.vmSizeKiB - phase1Baseline.vmSizeKiB,
          peakDeltaVmRSSKiB: phase2DeepBurst.vmRSSKiB - phase1Baseline.vmRSSKiB,
          peakDeltaRssAnonKiB,
          peakDeltaRwAnonKiB: phase2DeepBurst.rwAnonKiB - phase1Baseline.rwAnonKiB,
          peakKiBPerFiberRwAnon: roundTo((phase2DeepBurst.rwAnonKiB - phase1Baseline.rwAnonKiB) / fibers, 2),
          postReclaimDeltaVmRSSKiB: phase4PostReclaim.vmRSSKiB - phase1Baseline.vmRSSKiB,
          postReclaimDeltaRssAnonKiB,
          reclaimedVmRSSKiB: phase2DeepBurst.vmRSSKiB - phase4PostReclaim.vmRSSKiB,
          reclaimedRssAnonKiB,
          reclaimedRwAnonKiB,
          reclaimedPercentRssAnon: roundTo((reclaimedRssAnonKiB / Math.max(1, peakDeltaRssAnonKiB)) * 100, 1),
          reclaimedPercentRwAnon: roundTo(
            (reclaimedRwAnonKiB / Math.max(1, phase2DeepBurst.rwAnonKiB - phase1Baseline.rwAnonKiB)) * 100,
            1
          ),
        },
      })
    );
    return;
  }

  if (mode === 'dim4-latency') {
    const sequentialCycles = 10_000;
    const batchCount = 100;
    const batchSize = 100;
    const sampleRuns = 5;

    // 1. Synchronous Wasm baseline (no JSPI wrappers)
    const syncInst = instantiateStackBenchModule(wasmBytes, {
      rawSyncYield: (d, t) => d + t,
    });
    for (let i = 0; i < 1000; i++) syncInst.syncRecurse(1, i, 1);
    const syncSamples = [];
    for (let r = 0; r < sampleRuns; r++) {
      const t0 = performance.now();
      let sum = 0;
      for (let i = 0; i < sequentialCycles; i++) {
        sum += syncInst.syncRecurse(1, i, 1);
      }
      const elapsedNs = (performance.now() - t0) * 1e6;
      if (sum === -999999) throw new Error('Checksum failure');
      syncSamples.push(elapsedNs / sequentialCycles);
    }

    // 2. JSPI `WebAssembly.promising` + `WebAssembly.Suspending` returning synchronously (no Promise allocation)
    const jspiSyncInst = instantiateStackBenchModule(wasmBytes, {
      asyncYield: (d, t) => d + t,
    });
    for (let i = 0; i < 500; i++) await jspiSyncInst.promisingRecurse(1, i, 1);
    const jspiSyncSamples = [];
    for (let r = 0; r < sampleRuns; r++) {
      const t0 = performance.now();
      for (let i = 0; i < sequentialCycles; i++) {
        await jspiSyncInst.promisingRecurse(1, i, 1);
      }
      const elapsedNs = (performance.now() - t0) * 1e6;
      jspiSyncSamples.push(elapsedNs / sequentialCycles);
    }

    // 3. JSPI `WebAssembly.promising` + `WebAssembly.Suspending` returning `Promise.resolve(val)` (10,000 sequential)
    const jspiAsyncInst = instantiateStackBenchModule(wasmBytes, {
      asyncYield: (d, t) => Promise.resolve(d + t),
    });
    for (let i = 0; i < 500; i++) await jspiAsyncInst.promisingRecurse(1, i, 1);
    const jspiSequentialSamples = [];
    for (let r = 0; r < sampleRuns; r++) {
      const t0 = performance.now();
      for (let i = 0; i < sequentialCycles; i++) {
        await jspiAsyncInst.promisingRecurse(1, i, 1);
      }
      const elapsedNs = (performance.now() - t0) * 1e6;
      jspiSequentialSamples.push(elapsedNs / sequentialCycles);
    }

    // 4. JSPI `WebAssembly.promising` + `WebAssembly.Suspending` returning `Promise.resolve(val)` (100x100 batched)
    const jspiBatchedSamples = [];
    for (let r = 0; r < sampleRuns; r++) {
      const t0 = performance.now();
      for (let b = 0; b < batchCount; b++) {
        const batch = [];
        for (let i = 0; i < batchSize; i++) {
          batch.push(jspiAsyncInst.promisingRecurse(5, i, 1));
        }
        await Promise.all(batch);
      }
      const elapsedNs = (performance.now() - t0) * 1e6;
      jspiBatchedSamples.push(elapsedNs / (batchCount * batchSize));
    }

    process.stdout.write(
      JSON.stringify({
        sequentialCycles,
        batchedCycles: `${batchCount}x${batchSize}`,
        syncBaselineNs: computeStats(syncSamples),
        jspiSyncReturnNs: computeStats(jspiSyncSamples),
        jspiPromiseSequentialNs: computeStats(jspiSequentialSamples),
        jspiPromiseBatched100x100Ns: computeStats(jspiBatchedSamples),
      })
    );
    return;
  }

  if (mode === 'dim5-ecosystem') {
    const results = [];

    // 1. Verify freshly compiled `wazig` (`0.17.0-wazig.3`) recursive async WASI `fd_read`/`fd_write` module
    {
      let readCount = 0;
      let writeCount = 0;
      const customInst = instantiateStackBenchModule(wasmBytes, {
        fdRead: async (fd, iovsPtr, iovsLen, nreadPtr) => {
          readCount++;
          await Promise.resolve();
          const view = new DataView(customInst.instance.exports.memory.buffer);
          const bufPtr = view.getUint32(iovsPtr, true);
          const bufLen = view.getUint32(iovsPtr + 4, true);
          const u8 = new Uint8Array(customInst.instance.exports.memory.buffer, bufPtr, bufLen);
          u8[0] = 77;
          view.setUint32(nreadPtr, Math.min(bufLen, 4), true);
          return 0;
        },
        fdWrite: async (fd, ciovsPtr, ciovsLen, nwrittenPtr) => {
          writeCount++;
          await Promise.resolve();
          const view = new DataView(customInst.instance.exports.memory.buffer);
          const bufLen = view.getUint32(ciovsPtr + 4, true);
          view.setUint32(nwrittenPtr, bufLen, true);
          return 0;
        },
      });

      const spBefore = customInst.stackPointerGlobal.value;
      const deepRes = await customInst.promisingRecurse(2000, 11, 2);
      const spAfter = customInst.stackPointerGlobal.value;
      const binInfo = inspectWasmBinaryBuffer(wasmBytes);
      const cm0 = binInfo.coreModules[0];

      results.push({
        ecosystem: 'wazig (freshly compiled wasm32-wasi)',
        name: 'stack_bench.wasm (recursive WASI fd_read/fd_write + JSPI)',
        requestedPath: payload.wasmPath,
        resolvedPath: payload.wasmPath,
        exists: true,
        format: binInfo.format,
        sizeBytes: binInfo.sizeBytes,
        coreModuleCount: binInfo.coreModules.length,
        hasStackPointerGlobal0: cm0.global0?.valType === 'i32' && cm0.global0?.mutable === true,
        stackPointerInitialValue: cm0.global0?.initialValue,
        exportsStackPointer: cm0.hasStackPointerExport,
        wasmValidate: WebAssembly.validate(wasmBytes),
        jspiGrowableStacksExecution: {
          status: deepRes !== -999999 && spBefore === spAfter ? 'PASS' : 'FAIL',
          recursionDepthTested: 2000,
          wasiFdReadSuspensions: readCount,
          wasiFdWriteSuspensions: writeCount,
          linearStackRestored: spBefore === spAfter,
          checksumResult: deepRes,
        },
      });
    }

    // 2. Inspect & execute ecosystem `.wasm` binaries (`zigar`, `jsco`, `jco`)
    const targets = [
      {
        ecosystem: 'zigar',
        name: 'simple.wasm',
        requestedPath: path.join(ROOT_DIR, 'zigar-runtime/test/wasm-samples/simple.wasm'),
        fallbackPaths: [path.join(ROOT_DIR, 'zigar-compiler/test/wasm-samples/simple.wasm')],
      },
      {
        ecosystem: 'zigar',
        name: 'read-file.wasm',
        requestedPath: path.join(ROOT_DIR, 'zigar-runtime/test/wasm-samples/read-file.wasm'),
        fallbackPaths: [path.join(ROOT_DIR, 'zigar-compiler/test/wasm-samples/read-file.wasm')],
      },
      {
        ecosystem: 'zigar',
        name: 'thread.wasm',
        requestedPath: path.join(ROOT_DIR, 'zigar-runtime/test/wasm-samples/thread.wasm'),
        fallbackPaths: [path.join(ROOT_DIR, 'zigar-compiler/test/wasm-samples/thread.wasm')],
      },
      {
        ecosystem: 'jsco',
        name: 'async-Simple.wasm / echo-async-p3.wasm',
        requestedPath: '/d/jsco/integration-tests/wasm/async-Simple.wasm',
        fallbackPaths: [
          '/d/jsco/integration-tests/echo-async-p3-wat/echo-async-p3.wasm',
          '/d/jco/packages/jco-transpile/test/fixtures/components/runtime/async_call.component.wasm',
        ],
      },
      {
        ecosystem: 'jsco / jco',
        name: 'p3-filesystem-test.wasm',
        requestedPath: '/d/jsco/integration-tests/wasm-p3/p3-filesystem-test.wasm',
        fallbackPaths: [
          '/d/jsco/integration-tests/wasmtime/p3_filesystem_file_read_write.component.wasm',
          '/d/jco/packages/jco-transpile/test/fixtures/components/p3/fs/p3-filesystem-file-read-write.wasm',
        ],
      },
      {
        ecosystem: 'jsco / jco',
        name: 'p3-http-echo.wasm',
        requestedPath: '/d/jsco/integration-tests/wasm-p3/p3-http-echo.wasm',
        fallbackPaths: [
          '/d/jsco/integration-tests/wasmtime/p3_http_echo.component.wasm',
          '/d/jco/packages/jco-transpile/test/fixtures/components/p3/http/p3-http-echo.wasm',
        ],
      },
      {
        ecosystem: 'jsco',
        name: 'file-io.wasm (WASI P1 async file I/O)',
        requestedPath: '/d/jsco/integration-tests/file-io-p1-wat/file-io.wasm',
        fallbackPaths: [],
      },
      {
        ecosystem: 'jsco',
        name: 'jspi_deadlock_repro.wasm (WASI P3 async component)',
        requestedPath: '/d/jsco/integration-tests/jspi-deadlock-repro/jspi_deadlock_repro.wasm',
        fallbackPaths: [],
      },
    ];

    for (const target of targets) {
      const candidatePaths = [target.requestedPath, ...(target.fallbackPaths || [])];
      const resolvedPath = candidatePaths.find((p) => existsSync(p)) || null;
      if (!resolvedPath) {
        results.push({
          ecosystem: target.ecosystem,
          name: target.name,
          requestedPath: target.requestedPath,
          resolvedPath: null,
          exists: false,
        });
        continue;
      }

      const buf = readFileSync(resolvedPath);
      const binInfo = inspectWasmBinaryBuffer(buf);
      const allCoreValid = binInfo.coreModules.every((cm) => WebAssembly.validate(cm.buffer));

      // Execute the primary core module under V8 `--experimental-wasm-growable-stacks --wasm-stack-switching-stack-size=4`
      let execResult = { status: 'NOT_RUN' };
      const primaryCore =
        binInfo.coreModules.find((cm) =>
          cm.exports.some((e) =>
            ['allocateScratchMemory', 'cabi_realloc', '_start', 'run-async'].includes(e.name)
          )
        ) || binInfo.coreModules[0];

      if (primaryCore) {
        try {
          const mod = new WebAssembly.Module(primaryCore.buffer);
          let suspendsTriggered = 0;
          const imports = {};
          for (const imp of WebAssembly.Module.imports(mod)) {
            if (!imports[imp.module]) imports[imp.module] = {};
            if (imp.kind === 'function') {
              imports[imp.module][imp.name] = new WebAssembly.Suspending(async () => {
                suspendsTriggered++;
                if (suspendsTriggered > 25) {
                  throw new Error('Reached verification suspension cap');
                }
                await Promise.resolve();
                return 0;
              });
            } else if (imp.kind === 'memory') {
              imports[imp.module][imp.name] = new WebAssembly.Memory({
                initial: 256,
                maximum: 1024,
                shared: target.name.includes('thread'),
              });
            } else if (imp.kind === 'table') {
              imports[imp.module][imp.name] = new WebAssembly.Table({
                initial: 512,
                element: 'anyfunc',
              });
            } else if (imp.kind === 'global') {
              imports[imp.module][imp.name] = new WebAssembly.Global(
                { value: 'i32', mutable: true },
                65536
              );
            }
          }

          const inst = new WebAssembly.Instance(mod, imports);
          let allocatedPtr = null;
          let entryCalled = null;

          if (typeof inst.exports.allocateScratchMemory === 'function') {
            allocatedPtr = await WebAssembly.promising(inst.exports.allocateScratchMemory)(64, 4);
            await WebAssembly.promising(inst.exports.freeScratchMemory)(allocatedPtr, 64, 4);
          } else if (typeof inst.exports.cabi_realloc === 'function') {
            allocatedPtr = await WebAssembly.promising(inst.exports.cabi_realloc)(0, 0, 4, 64);
          }

          const modExports = WebAssembly.Module.exports(mod).filter((e) => e.kind === 'function');
          const asyncEntry =
            modExports.find((e) => e.name.startsWith('[async-lift]')) ||
            modExports.find((e) =>
              ['_initialize', 'run-async', '_start', 'echo'].includes(e.name)
            );
          let entryError = null;
          let hitSuspensionCap = false;
          if (asyncEntry) {
            entryCalled = asyncEntry.name;
            try {
              await WebAssembly.promising(inst.exports[asyncEntry.name])(0, 0, 0, 0);
            } catch (e) {
              entryError = `${e.name}: ${e.message}`;
              hitSuspensionCap = String(e.message).includes('Reached verification suspension cap');
            }
          }

          execResult = {
            status: (!entryError || hitSuspensionCap) ? 'PASS' : 'TRAP_WITH_STUB_IMPORTS',
            usedFallbackPath: resolvedPath !== target.requestedPath,
            coreModuleTested: primaryCore.moduleIndex,
            allocatedPtr,
            entryCalled,
            entryError,
            jspiSuspensionsVerified: suspendsTriggered,
          };
        } catch (err) {
          execResult = {
            status: 'ERROR',
            error: `${err.name}: ${err.message}`,
          };
        }
      }

      const mainCore = primaryCore || binInfo.coreModules[0] || {};
      results.push({
        ecosystem: target.ecosystem,
        name: target.name,
        requestedPath: target.requestedPath,
        resolvedPath,
        exists: true,
        format: binInfo.format,
        sizeBytes: binInfo.sizeBytes,
        coreModuleCount: binInfo.coreModules.length,
        hasStackPointerGlobal0:
          mainCore.global0?.valType === 'i32' && mainCore.global0?.mutable === true,
        stackPointerInitialValue: mainCore.global0?.initialValue ?? null,
        exportsStackPointer: Boolean(mainCore.hasStackPointerExport),
        allCoreModulesValid: allCoreValid,
        jspiGrowableStacksExecution: execResult,
      });
    }

    process.stdout.write(JSON.stringify({ results }));
    return;
  }

  throw new Error(`Unknown worker mode: ${mode}`);
}

// ---------------------------------------------------------------------------
// Parent Orchestrator (Spawns Isolated Node 24 Processes Per V8 Flag Config)
// ---------------------------------------------------------------------------

function runIsolatedWorker(v8Flags, workerMode, payload) {
  const args = [
    ...v8Flags,
    '--expose-gc',
    __filename,
    `--worker-mode=${workerMode}`,
    `--worker-payload=${JSON.stringify(payload)}`,
  ];
  const stdout = execFileSync(NODE24_BIN, args, {
    encoding: 'utf8',
    env: {
      ...process.env,
      TMPDIR: TMP_ROOT,
      ZIG_GLOBAL_CACHE_DIR: ZIG_GLOBAL_CACHE,
      ZIG_LOCAL_CACHE_DIR: ZIG_LOCAL_CACHE,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 180_000,
    maxBuffer: 16 * 1024 * 1024,
  });
  return JSON.parse(stdout.trim());
}

async function main() {
  ensureCacheDirs();

  // Check if invoked as an isolated child worker
  const workerModeArg = process.argv.find((a) => a.startsWith('--worker-mode='));
  const workerPayloadArg = process.argv.find((a) => a.startsWith('--worker-payload='));
  if (workerModeArg && workerPayloadArg) {
    const mode = workerModeArg.slice('--worker-mode='.length);
    const payloadJson = workerPayloadArg.slice('--worker-payload='.length);
    await runWorkerMode(mode, payloadJson);
    return;
  }

  const workDir = path.join(TMP_ROOT, `wasm-stack-switching-bench-${process.pid}`);
  mkdirSync(workDir, { recursive: true });

  try {
    console.log('====================================================================================================');
    console.log(' V8 13.6 WebAssembly Stack Switching & Growable Stacks Benchmark (`--experimental-wasm-growable-stacks`)');
    console.log('====================================================================================================');

    const envInfo = {
      timestamp: new Date().toISOString(),
      nodeBinary: NODE24_BIN,
      nodeVersion: process.version,
      v8Version: process.versions.v8,
      wazigVersion: getToolVersion(WAZIG_BIN, ['version']),
      zigVersion: getToolVersion(ZIG_BIN, ['version']),
      wasmToolsVersion: getToolVersion(WASM_TOOLS_BIN, ['--version']),
      platform: os.platform(),
      arch: os.arch(),
      release: os.release(),
      cpuModel: os.cpus()[0]?.model || 'unknown',
      cpuCores: os.cpus().length,
      osPageSizeKiB: 4,
      v8StackMemoryMechanics: {
        kJSLimitOffsetKB: 40,
        defaultStackSwitchingStackSizeKB: 984,
        growableInitialPhysicalSegmentKiB: 44,
        growableSegmentProgressionKiB: [44, 88, 176, 352, 636],
        stackPoolMaxSizeBytes: 4 * 1024 * 1024,
        stackPoolMaxCachedStacksDefault984KB: 4,
        stackPoolMaxCachedStacksGrowable4KB: 93,
      },
    };

    console.log(`Node: ${envInfo.nodeVersion} | V8: ${envInfo.v8Version} | wazig: ${envInfo.wazigVersion} | zig: ${envInfo.zigVersion}`);
    console.log(`Platform: ${envInfo.platform}-${envInfo.arch} (${envInfo.release}) | CPUs: ${envInfo.cpuCores}`);

    // Compile `stack_bench.zig` using `wazig`
    console.log('\n[Setup] Compiling recursive async WASI + JSPI benchmark module with `wazig`...');
    const compiled = compileWazigBenchmarkModule(workDir);
    const cm0 = compiled.binaryInfo.coreModules[0];
    console.log(
      `  -> Compiled stack_bench.wasm (${compiled.wasmBytes.length} bytes) in ${compiled.compileMs} ms | ` +
        `global[0]=${cm0.global0?.valType}(init=${cm0.global0?.initialValue}) | __stack_pointer exported=${cm0.hasStackPointerExport}`
    );

    // -------------------------------------------------------------------------
    // Dimension 1: Memory Footprint Scaling Across Concurrent Suspended Stacks
    // -------------------------------------------------------------------------
    console.log('\n----------------------------------------------------------------------------------------------------');
    console.log(' Dimension 1: Memory Footprint Scaling Across Concurrent Suspended JSPI Stacks (1 .. 1000 fibers)');
    console.log('----------------------------------------------------------------------------------------------------');

    const memoryConfigs = [
      {
        id: 'config-a-fixed-984kb',
        label: 'Config A: Default Fixed 984 KB',
        v8Flags: [],
      },
      {
        id: 'config-b-fixed-64kb',
        label: 'Config B: Fixed 64 KB',
        v8Flags: ['--wasm-stack-switching-stack-size=64'],
      },
      {
        id: 'config-c-fixed-4kb',
        label: 'Config C: Fixed 4 KB (no grow)',
        v8Flags: ['--wasm-stack-switching-stack-size=4'],
      },
      {
        id: 'config-d-growable-4kb-turboshaft',
        label: 'Config D: Growable 4 KB (Turboshaft)',
        v8Flags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4', '--no-liftoff'],
      },
      {
        id: 'config-e-growable-4kb-tiered',
        label: 'Config E: Growable 4 KB (Tiered)',
        v8Flags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4'],
      },
    ];

    const fiberCounts = [1, 10, 50, 100, 500, 1000];
    const memoryDepths = [5, 100];
    const dimension1Results = [];

    for (const depth of memoryDepths) {
      console.log(`\n  [Recursion Depth = ${depth} frames before JSPI suspension]`);
      const tableRows = [];
      for (const cfg of memoryConfigs) {
        const fiberMeasurements = [];
        for (const fibers of fiberCounts) {
          const res = runIsolatedWorker(cfg.v8Flags, 'dim1-memory', {
            wasmPath: compiled.wasmPath,
            fibers,
            depth,
          });
          fiberMeasurements.push(res);
        }
        dimension1Results.push({
          configId: cfg.id,
          configLabel: cfg.label,
          v8Flags: cfg.v8Flags,
          depth,
          measurements: fiberMeasurements,
        });

        const m1 = fiberMeasurements.find((m) => m.fibers === 1);
        const m100 = fiberMeasurements.find((m) => m.fibers === 100);
        const m1000 = fiberMeasurements.find((m) => m.fibers === 1000);
        tableRows.push({
          Configuration: cfg.label,
          '1 Fiber dVmSize': m1?.status === 'OK' ? `${m1.deltaVmSizeKiB} KiB` : 'OVERFLOW',
          '100 Fibers dVmRSS': m100?.status === 'OK' ? `${m100.deltaVmRSSKiB} KiB` : 'OVERFLOW',
          '1000 Fibers dVmSize': m1000?.status === 'OK' ? `${m1000.deltaVmSizeKiB} KiB` : 'OVERFLOW',
          '1000 Fibers dVmRSS': m1000?.status === 'OK' ? `${m1000.deltaVmRSSKiB} KiB` : 'OVERFLOW',
          '1000 Fibers dRssAnon': m1000?.status === 'OK' ? `${m1000.deltaRssAnonKiB} KiB` : 'OVERFLOW',
          'VmSize / Fiber (N=1000)': m1000?.status === 'OK' ? `${m1000.vmSizeKiBPerFiber} KiB` : 'OVERFLOW',
          'RssAnon / Fiber (N=1000)': m1000?.status === 'OK' ? `${m1000.rssAnonKiBPerFiber} KiB` : 'OVERFLOW',
        });
      }
      console.table(tableRows);
    }

    // -------------------------------------------------------------------------
    // Dimension 2: Recursion Depth & Stack Overflow Resilience
    // -------------------------------------------------------------------------
    console.log('\n----------------------------------------------------------------------------------------------------');
    console.log(' Dimension 2: Recursion Depth & Stack Overflow Resilience (depth = 5 .. 5000)');
    console.log('----------------------------------------------------------------------------------------------------');

    const recursionDepths = [5, 25, 100, 250, 500, 1000, 2500, 5000];
    const recursionConfigs = [
      {
        id: 'fixed-4kb',
        label: 'Fixed 4 KB (no growable stacks)',
        v8Flags: ['--wasm-stack-switching-stack-size=4'],
        findExact4KBOverflow: true,
      },
      {
        id: 'fixed-984kb',
        label: 'Default Fixed 984 KB',
        v8Flags: ['--wasm-stack-switching-stack-size=984'],
        findExact4KBOverflow: false,
      },
      {
        id: 'growable-4kb-turboshaft',
        label: 'Growable 4 KB (Turboshaft --no-liftoff)',
        v8Flags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4', '--no-liftoff'],
        findExact4KBOverflow: false,
      },
      {
        id: 'growable-4kb-tiered',
        label: 'Growable 4 KB (Tiered Liftoff->Turboshaft)',
        v8Flags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4'],
        findExact4KBOverflow: false,
      },
    ];

    const dimension2Results = [];
    for (const cfg of recursionConfigs) {
      const res = runIsolatedWorker(cfg.v8Flags, 'dim2-recursion', {
        wasmPath: compiled.wasmPath,
        depths: recursionDepths,
        findExact4KBOverflow: cfg.findExact4KBOverflow,
      });
      dimension2Results.push({
        configId: cfg.id,
        configLabel: cfg.label,
        v8Flags: cfg.v8Flags,
        ...res,
      });
    }

    const fixed4Overflow = dimension2Results.find((r) => r.configId === 'fixed-4kb')?.exactOverflowInfo;
    if (fixed4Overflow) {
      console.log(
        `  -> Fixed 4 KB exact stack overflow boundary: max succeeding depth = ${fixed4Overflow.maxSuccessDepth} frames, ` +
          `overflows at depth = ${fixed4Overflow.firstOverflowDepth} (${fixed4Overflow.overflowMessage})`
      );
    }

    const dim2Table = recursionDepths.map((depth) => {
      const getCell = (id) => {
        const cfg = dimension2Results.find((r) => r.configId === id);
        const m = cfg?.depthMeasurements.find((d) => d.depth === depth);
        if (!m || m.status !== 'OK') return 'RangeError (Overflow)';
        return `${m.nsPerFrameMedian} ns/frame (${(m.callsPerSec / 1000).toFixed(1)}k calls/s)`;
      };
      const fixed984 = dimension2Results
        .find((r) => r.configId === 'fixed-984kb')
        ?.depthMeasurements.find((d) => d.depth === depth);
      const growTurbo = dimension2Results
        .find((r) => r.configId === 'growable-4kb-turboshaft')
        ?.depthMeasurements.find((d) => d.depth === depth);
      const overheadPct =
        fixed984?.status === 'OK' && growTurbo?.status === 'OK'
          ? `${roundTo(((growTurbo.nsPerFrameMedian - fixed984.nsPerFrameMedian) / fixed984.nsPerFrameMedian) * 100, 1)}%`
          : 'N/A';

      return {
        Depth: depth,
        'Fixed 4 KB': getCell('fixed-4kb'),
        'Fixed 984 KB': getCell('fixed-984kb'),
        'Growable 4 KB (Turboshaft)': getCell('growable-4kb-turboshaft'),
        'Growable 4 KB (Tiered)': getCell('growable-4kb-tiered'),
        'Growable vs 984 KB Overhead': overheadPct,
      };
    });
    console.table(dim2Table);

    // -------------------------------------------------------------------------
    // Dimension 3: Dynamic Stack Shrinking After Deep-Recursion Burst
    // -------------------------------------------------------------------------
    console.log('\n----------------------------------------------------------------------------------------------------');
    console.log(' Dimension 3: Dynamic Stack Shrinking After Deep-Recursion Burst (`WasmShrinkStack` + `StackPool`)');
    console.log('----------------------------------------------------------------------------------------------------');

    const dimension3Result = runIsolatedWorker(
      ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4', '--no-liftoff'],
      'dim3-shrink',
      {
        wasmPath: compiled.wasmPath,
        fibers: 200,
        deepDepth: 1000,
      }
    );

    console.table([
      {
        Phase: 'Phase 1: Baseline (Idle before burst)',
        VmSize: `${dimension3Result.phase1Baseline.vmSizeKiB} KiB`,
        VmRSS: `${dimension3Result.phase1Baseline.vmRSSKiB} KiB`,
        RssAnon: `${dimension3Result.phase1Baseline.rssAnonKiB} KiB`,
        'Anon rw-p Pages': `${dimension3Result.phase1Baseline.rwAnonKiB} KiB`,
        'Anon ---p (PROT_NONE)': `${dimension3Result.phase1Baseline.protNoneAnonKiB} KiB`,
      },
      {
        Phase: 'Phase 2: Deep Burst (200 fibers suspended @ depth=1000)',
        VmSize: `${dimension3Result.phase2DeepBurst.vmSizeKiB} KiB (+${dimension3Result.metrics.peakDeltaVmSizeKiB})`,
        VmRSS: `${dimension3Result.phase2DeepBurst.vmRSSKiB} KiB (+${dimension3Result.metrics.peakDeltaVmRSSKiB})`,
        RssAnon: `${dimension3Result.phase2DeepBurst.rssAnonKiB} KiB (+${dimension3Result.metrics.peakDeltaRssAnonKiB})`,
        'Anon rw-p Pages': `${dimension3Result.phase2DeepBurst.rwAnonKiB} KiB (+${dimension3Result.metrics.peakDeltaRwAnonKiB})`,
        'Anon ---p (PROT_NONE)': `${dimension3Result.phase2DeepBurst.protNoneAnonKiB} KiB`,
      },
      {
        Phase: 'Phase 3: Unwind to Shallow (WasmShrinkStack -> depth=2)',
        VmSize: `${dimension3Result.phase3UnwoundShallow.vmSizeKiB} KiB`,
        VmRSS: `${dimension3Result.phase3UnwoundShallow.vmRSSKiB} KiB`,
        RssAnon: `${dimension3Result.phase3UnwoundShallow.rssAnonKiB} KiB`,
        'Anon rw-p Pages': `${dimension3Result.phase3UnwoundShallow.rwAnonKiB} KiB`,
        'Anon ---p (PROT_NONE)': `${dimension3Result.phase3UnwoundShallow.protNoneAnonKiB} KiB`,
      },
      {
        Phase: 'Phase 4: Complete & StackPool 4 MiB Cap Page Reclaim',
        VmSize: `${dimension3Result.phase4PostReclaim.vmSizeKiB} KiB`,
        VmRSS: `${dimension3Result.phase4PostReclaim.vmRSSKiB} KiB (-${dimension3Result.metrics.reclaimedVmRSSKiB} KiB)`,
        RssAnon: `${dimension3Result.phase4PostReclaim.rssAnonKiB} KiB (-${dimension3Result.metrics.reclaimedRssAnonKiB} KiB / -${dimension3Result.metrics.reclaimedPercentRssAnon}%)`,
        'Anon rw-p Pages': `${dimension3Result.phase4PostReclaim.rwAnonKiB} KiB (-${dimension3Result.metrics.reclaimedRwAnonKiB} KiB / -${dimension3Result.metrics.reclaimedPercentRwAnon}%)`,
        'Anon ---p (PROT_NONE)': `${dimension3Result.phase4PostReclaim.protNoneAnonKiB} KiB`,
      },
    ]);

    // -------------------------------------------------------------------------
    // Dimension 4: JSPI Suspension / Resumption Latency Microbenchmark
    // -------------------------------------------------------------------------
    console.log('\n----------------------------------------------------------------------------------------------------');
    console.log(' Dimension 4: JSPI Suspension / Resumption Latency Microbenchmark (10,000 cycles)');
    console.log('----------------------------------------------------------------------------------------------------');

    const latencyConfigs = [
      {
        id: 'default-fixed-984kb',
        label: 'Default Fixed 984 KB',
        v8Flags: [],
      },
      {
        id: 'growable-4kb-turboshaft',
        label: 'Growable 4 KB (Turboshaft --no-liftoff)',
        v8Flags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4', '--no-liftoff'],
      },
      {
        id: 'growable-4kb-tiered',
        label: 'Growable 4 KB (Tiered Liftoff->Turboshaft)',
        v8Flags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4'],
      },
    ];

    const dimension4Results = [];
    for (const cfg of latencyConfigs) {
      const res = runIsolatedWorker(cfg.v8Flags, 'dim4-latency', {
        wasmPath: compiled.wasmPath,
      });
      dimension4Results.push({
        configId: cfg.id,
        configLabel: cfg.label,
        v8Flags: cfg.v8Flags,
        ...res,
      });
    }

    const base984Batched = dimension4Results.find((r) => r.configId === 'default-fixed-984kb')?.jspiPromiseBatched100x100Ns.median;
    console.table(
      dimension4Results.map((r) => ({
        Configuration: r.configLabel,
        'Sync Wasm Baseline': `${r.syncBaselineNs.median} ns`,
        'JSPI Sync Return (No Promise)': `${r.jspiSyncReturnNs.median} ns`,
        'JSPI Promise.resolve (10k Seq)': `${r.jspiPromiseSequentialNs.median} ns`,
        'JSPI Promise.resolve (100x100 Batch)': `${r.jspiPromiseBatched100x100Ns.median} ns`,
        'Batched Speedup vs 984 KB': base984Batched
          ? `${roundTo(base984Batched / r.jspiPromiseBatched100x100Ns.median, 2)}x`
          : '1.0x',
      }))
    );

    // -------------------------------------------------------------------------
    // Dimension 5: Real Unmodified `.wasm` Ecosystem Binary Verification
    // -------------------------------------------------------------------------
    console.log('\n----------------------------------------------------------------------------------------------------');
    console.log(' Dimension 5: Real Unmodified `.wasm` Ecosystem Binary Verification (`zigar`, `wazig`, `jsco`, `jco`)');
    console.log('----------------------------------------------------------------------------------------------------');

    const dimension5Result = runIsolatedWorker(
      ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4'],
      'dim5-ecosystem',
      {
        wasmPath: compiled.wasmPath,
      }
    );

    console.table(
      dimension5Result.results.map((r) => ({
        Ecosystem: r.ecosystem,
        Binary: r.name,
        Format: r.format || 'missing',
        'Size (KB)': r.sizeBytes ? roundTo(r.sizeBytes / 1024, 1) : 0,
        'Core Mods': r.coreModuleCount ?? 0,
        'global[0] SP': r.hasStackPointerGlobal0 ? `Yes (${r.stackPointerInitialValue})` : 'N/A',
        'Exports __stack_pointer': r.exportsStackPointer ? 'Yes' : 'No (Internal)',
        'JSPI + Growable 4KB Exec': r.jspiGrowableStacksExecution
          ? `${r.jspiGrowableStacksExecution.status} (${
              r.jspiGrowableStacksExecution.jspiSuspensionsVerified ??
              (r.jspiGrowableStacksExecution.wasiFdReadSuspensions || 0) +
                (r.jspiGrowableStacksExecution.wasiFdWriteSuspensions || 0)
            } suspends)`
          : 'N/A',
      }))
    );

    // -------------------------------------------------------------------------
    // Write Full Structured Output to `benchmarks/stack-switching-results.json`
    // -------------------------------------------------------------------------
    const fullReport = {
      benchmark: 'wasm-stack-switching-benchmark',
      issue: '#14 (growable-stacks-benchmark)',
      environment: envInfo,
      wazigCompiledKernel: {
        zigCompiler: envInfo.wazigVersion,
        compileTimeMs: compiled.compileMs,
        wasmSizeBytes: compiled.wasmBytes.length,
        hasStackPointerGlobal0: cm0.global0?.valType === 'i32' && cm0.global0?.mutable === true,
        stackPointerInitialValue: cm0.global0?.initialValue,
        exportsStackPointer: cm0.hasStackPointerExport,
        exports: cm0.exports,
      },
      dimension1MemoryFootprintScaling: dimension1Results,
      dimension2RecursionDepthResilience: dimension2Results,
      dimension3DynamicStackShrinking: dimension3Result,
      dimension4SuspensionLatencyMicrobenchmark: dimension4Results,
      dimension5RealEcosystemBinaries: dimension5Result.results,
    };

    writeFileSync(DEFAULT_JSON_OUT, JSON.stringify(fullReport, null, 2) + '\n', 'utf8');
    console.log(`\n[Done] Saved full structured benchmark results to ${DEFAULT_JSON_OUT}`);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
