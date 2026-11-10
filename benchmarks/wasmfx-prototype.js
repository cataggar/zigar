#!/usr/bin/env node
'use strict';

/**
 * WasmFX (Typed Continuations) & Dual-Stack (__stack_pointer / global[0]) Prototype
 * Issue #14: Explore WebAssembly Stack Switching (JSPI & WasmFX)
 *
 * Empirically tests:
 *  1. V8 13.6 (Node 24.21.0) `--experimental-wasm-wasmfx` wire-format validation,
 *     type-system support (`0x5d` cont $type_idx, `0x68` contref, `0x75` nullcontref),
 *     instantiation behavior (`CreateMapForType`), and instruction opcode matrix (`0xe0..0xef`).
 *  2. Wasmtime 50.0.1 (`-W stack-switching=y -W exceptions=y -W function-references=y`)
 *     Cranelift x86_64 AOT compilation of all 7 WasmFX instructions (`0xe0..0xe6`),
 *     ELF64 `.cwasm` symbol table + `wasmtime objdump` inline `%rsp`/`%rbp`/`%rip` switch
 *     disassembly, and `aarch64` target diagnostic verification.
 *  3. Executable Dual-Stack (`__stack_pointer` / `global[0]`) Context-Switching Prototype
 *     and Benchmark on both a synthetic Wasm binary and a real `wazig` (`0.17.0-wazig.6`) compiled Zig `.wasm`
 *     module (`-target wasm32-wasi -O ReleaseSmall -fno-entry -rdynamic`) across 50 concurrent
 *     out-of-order fibers (depth = 20, 1,000 suspensions), proving silent linear shadow stack
 *     corruption when sharing `global[0]` vs 100% isolation when switching `global[0]`.
 */

const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const os = require('os');
const LOCAL_BIN_DIR = path.join(os.homedir(), '.local', 'bin');
if (fs.existsSync(LOCAL_BIN_DIR) && !(process.env.PATH || '').split(':').includes(LOCAL_BIN_DIR)) {
  process.env.PATH = `${LOCAL_BIN_DIR}:${process.env.PATH || ''}`;
}

const NODE24_BIN = process.env.NODE24_BIN || (fs.existsSync('/opt/actions-runner/2.338.0/externals/node24/bin/node')
  ? '/opt/actions-runner/2.338.0/externals/node24/bin/node'
  : process.execPath);
const WASMTIME_BIN = process.env.WASMTIME_BIN || (fs.existsSync(path.join(LOCAL_BIN_DIR, 'wasmtime')) ? path.join(LOCAL_BIN_DIR, 'wasmtime') : 'wasmtime');
const WAZIG_BIN = process.env.WAZIG_BIN || (fs.existsSync(path.join(LOCAL_BIN_DIR, 'wazig')) ? path.join(LOCAL_BIN_DIR, 'wazig') : 'wazig');
const TMP_ROOT = process.env.TMP_ROOT || '/d/zigar-worktrees/.cache/tmp';
const WORK_DIR = path.join(TMP_ROOT, `wasmfx-proto-${process.pid}`);
const RESULTS_PATH = path.join(__dirname, 'wasmfx-results.json');

// ---------------------------------------------------------------------------
// Minimal Wasm Binary Encoder Helpers
// ---------------------------------------------------------------------------

function uleb128(value) {
  const bytes = [];
  let v = value >>> 0;
  do {
    let b = v & 0x7f;
    v >>>= 7;
    if (v !== 0) b |= 0x80;
    bytes.push(b);
  } while (v !== 0);
  return bytes;
}

function sleb128(value) {
  const bytes = [];
  let v = value | 0;
  let more = true;
  while (more) {
    let b = v & 0x7f;
    v >>= 7;
    if ((v === 0 && (b & 0x40) === 0) || (v === -1 && (b & 0x40) !== 0)) {
      more = false;
    } else {
      b |= 0x80;
    }
    bytes.push(b);
  }
  return bytes;
}

function encodeSection(id, payload) {
  return [id, ...uleb128(payload.length), ...payload];
}

function encodeString(str) {
  const buf = Buffer.from(str, 'utf8');
  return [...uleb128(buf.length), ...buf];
}

function encodeFuncBody(locals, instructions) {
  const body = [...locals, ...instructions, 0x0b];
  return [...uleb128(body.length), ...body];
}

function encodeWasmModule(sections) {
  const bytes = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  for (const sec of sections) {
    bytes.push(...sec);
  }
  return new Uint8Array(bytes);
}

// ---------------------------------------------------------------------------
// Subprocess Helper for V8 Flag Probes
// ---------------------------------------------------------------------------

function runNodeEval(flags, code) {
  const res = spawnSync(NODE24_BIN, [...flags, '-e', code], {
    env: { ...process.env, TMPDIR: TMP_ROOT },
    encoding: 'utf8',
    timeout: 15000,
  });
  return {
    status: res.status,
    signal: res.signal,
    stdout: (res.stdout || '').trim(),
    stderr: (res.stderr || '').trim(),
  };
}

function probeBytesInV8(wasmBytes, flags = []) {
  const hex = Buffer.from(wasmBytes).toString('hex');
  const script = `
    const bytes = Uint8Array.from(Buffer.from(${JSON.stringify(hex)}, 'hex'));
    const valid = WebAssembly.validate(bytes);
    let compiled = false;
    let compileError = null;
    let exportsList = null;
    try {
      const mod = new WebAssembly.Module(bytes);
      compiled = true;
      exportsList = WebAssembly.Module.exports(mod);
    } catch (err) {
      compileError = err.message;
    }
    console.log(JSON.stringify({ valid, compiled, compileError, exportsList }));
  `;
  const res = runNodeEval(flags, script);
  try {
    return JSON.parse(res.stdout);
  } catch {
    return {
      valid: false,
      compiled: false,
      compileError: res.stderr || res.stdout || `exit ${res.status}`,
      exportsList: null,
    };
  }
}

function probeInstantiateInV8(wasmBytes, flags = []) {
  const hex = Buffer.from(wasmBytes).toString('hex');
  const script = `
    const bytes = Uint8Array.from(Buffer.from(${JSON.stringify(hex)}, 'hex'));
    const mod = new WebAssembly.Module(bytes);
    const inst = new WebAssembly.Instance(mod);
    const ret = inst.exports.run ? inst.exports.run() : null;
    console.log(JSON.stringify({ instantiated: true, returnValue: ret }));
  `;
  const res = runNodeEval(flags, script);
  if (res.status === 0) {
    try {
      return { ...JSON.parse(res.stdout), exitCode: 0, fatalError: null };
    } catch {
      return { instantiated: false, returnValue: null, exitCode: res.status, fatalError: res.stdout };
    }
  }
  const fatalMatch = res.stderr.match(/Fatal error[^\n]*\n#\s*([^\n]+)/);
  return {
    instantiated: false,
    returnValue: null,
    exitCode: res.status,
    fatalError: fatalMatch ? fatalMatch[1].trim() : res.stderr.split('\n').slice(0, 6).join(' | '),
  };
}

// ---------------------------------------------------------------------------
// PART 1: V8 13.6 `--experimental-wasm-wasmfx` Wire-Format & Opcode Matrix
// ---------------------------------------------------------------------------

function runPart1V8WasmFXMatrix() {
  const wasmfxFlags = ['--experimental-wasm-wasmfx', '--experimental-wasm-exnref'];

  // 1A: Concrete continuation type (0x5d cont $ft) + local (ref null $ct)
  const modConcreteContLocal = encodeWasmModule([
    encodeSection(1, [
      3,
      0x60, 0x00, 0x00,       // type 0: (func)
      0x5d, 0x00,             // type 1: (cont 0)
      0x60, 0x00, 0x01, 0x7f, // type 2: (func (result i32))
    ]),
    encodeSection(3, [1, 0x02]),
    encodeSection(7, [1, ...encodeString('run'), 0x00, 0x00]),
    encodeSection(10, [
      1,
      // 1 local of (ref null 1) [0x63, 0x01], ref.null 1 [0xd0, 0x01], ref.is_null [0xd1]
      ...encodeFuncBody([1, 1, 0x63, 0x01], [0xd0, 0x01, 0xd1]),
    ]),
  ]);

  // 1B: Concrete continuation in Table, Global, Function Param & Return
  const modConcreteContTableGlobalParam = encodeWasmModule([
    encodeSection(1, [
      4,
      0x60, 0x00, 0x00,                         // type 0: (func)
      0x5d, 0x00,                               // type 1: (cont 0)
      0x60, 0x01, 0x63, 0x01, 0x01, 0x63, 0x01, // type 2: (func (param (ref null 1)) (result (ref null 1)))
      0x60, 0x00, 0x01, 0x7f,                   // type 3: (func (result i32))
    ]),
    encodeSection(3, [2, 0x02, 0x03]),
    encodeSection(4, [1, 0x63, 0x01, 0x00, 0x04]), // table 0: 4 (ref null 1)
    encodeSection(6, [1, 0x63, 0x01, 0x01, 0xd0, 0x01, 0x0b]), // global 0: (mut (ref null 1)) (ref.null 1)
    encodeSection(7, [
      3,
      ...encodeString('run'), 0x00, 0x01,
      ...encodeString('tbl'), 0x01, 0x00,
      ...encodeString('glb'), 0x03, 0x00,
    ]),
    encodeSection(10, [
      2,
      ...encodeFuncBody([0], [0x20, 0x00]), // func 0: local.get 0
      ...encodeFuncBody(
        [1, 1, 0x63, 0x01],
        [0x23, 0x00, 0x10, 0x00, 0x22, 0x00, 0xd1] // global.get 0, call 0, local.tee 0, ref.is_null
      ),
    ]),
  ]);

  // 1C: Recursive type group (`0x4e`) + `sub` (`0x50`) / `sub final` (`0x4f`) with `0x5d` (cont)
  const modRecGroupContSubtyping = encodeWasmModule([
    encodeSection(1, [
      2,
      // rec group of 2 types:
      0x4e, 2,
      0x50, 0x00, 0x60, 0x00, 0x01, 0x7f, // type 0: (sub (func (result i32)))
      0x50, 0x00, 0x5d, 0x00,             // type 1: (sub (cont 0))
      0x60, 0x00, 0x01, 0x7f,             // type 2: (func (result i32))
    ]),
    encodeSection(3, [1, 0x02]),
    encodeSection(7, [1, ...encodeString('run'), 0x00, 0x00]),
    encodeSection(10, [
      1,
      ...encodeFuncBody([1, 1, 0x63, 0x01], [0xd0, 0x01, 0xd1]),
    ]),
  ]);

  // 1D: Abstract `contref` (`0x68` / `(ref null cont)`) in Table, Global, Param, Local
  const modAbstractContref = encodeWasmModule([
    encodeSection(1, [
      2,
      0x60, 0x01, 0x68, 0x01, 0x68, // type 0: (func (param contref) (result contref))
      0x60, 0x00, 0x01, 0x7f,       // type 1: (func (result i32))
    ]),
    encodeSection(3, [2, 0x00, 0x01]),
    encodeSection(4, [1, 0x68, 0x00, 0x04]), // table 0: 4 contref
    encodeSection(6, [1, 0x68, 0x01, 0xd0, 0x68, 0x0b]), // global 0: (mut contref) (ref.null cont)
    encodeSection(7, [1, ...encodeString('run'), 0x00, 0x01]),
    encodeSection(10, [
      2,
      ...encodeFuncBody([0], [0x20, 0x00]),
      ...encodeFuncBody(
        [1, 1, 0x68],
        [0x23, 0x00, 0x10, 0x00, 0x22, 0x00, 0xd1]
      ),
    ]),
  ]);

  // 1E: Abstract `nullcontref` (`0x75` / `(ref null nocont)`) coerced to `contref` (`0x68`)
  const modAbstractNullContref = encodeWasmModule([
    encodeSection(1, [
      1,
      0x60, 0x00, 0x01, 0x7f, // type 0: (func (result i32))
    ]),
    encodeSection(3, [1, 0x00]),
    encodeSection(6, [1, 0x68, 0x01, 0xd0, 0x75, 0x0b]), // global 0: contref initialized with ref.null nocont (0x75)!
    encodeSection(7, [1, ...encodeString('run'), 0x00, 0x00]),
    encodeSection(10, [
      1,
      ...encodeFuncBody([1, 1, 0x75], [0xd0, 0x75, 0x21, 0x00, 0x23, 0x00, 0xd1]),
    ]),
  ]);

  const typeTests = [
    {
      id: 'concrete_cont_local',
      description: 'Concrete (type $ct (cont $ft)) [0x5d 0x00] + local (ref null $ct) [0x63 0x01]',
      bytes: modConcreteContLocal,
    },
    {
      id: 'concrete_cont_table_global_sig',
      description: 'Concrete (ref null $ct) in Table, Global, and Function (param)/(result)',
      bytes: modConcreteContTableGlobalParam,
    },
    {
      id: 'rec_group_cont_subtyping',
      description: 'Recursive type group (0x4e) with subtyping (0x50 sub (cont $ft))',
      bytes: modRecGroupContSubtyping,
    },
    {
      id: 'abstract_contref_0x68',
      description: 'Abstract contref (0x68) in Table, Global, Param, Return, Local + Execution',
      bytes: modAbstractContref,
    },
    {
      id: 'abstract_nullcontref_0x75',
      description: 'Abstract nullcontref (0x75 nocont) subtyping into contref (0x68) + Execution',
      bytes: modAbstractNullContref,
    },
  ];

  const typeMatrixResults = typeTests.map((t) => {
    const withoutFlag = probeBytesInV8(t.bytes, []);
    const withFlag = probeBytesInV8(t.bytes, wasmfxFlags);
    const instantiation = withFlag.compiled ? probeInstantiateInV8(t.bytes, wasmfxFlags) : null;
    return {
      id: t.id,
      description: t.description,
      moduleSizeBytes: t.bytes.length,
      withoutWasmFXFlag: withoutFlag,
      withWasmFXFlag: withFlag,
      instantiationWithWasmFXFlag: instantiation,
    };
  });

  // 1F: WasmFX Instruction Opcode Matrix (0xe0 .. 0xef)
  // For 0xe0..0xe6 we construct 100% spec-compliant WasmFX binaries (verified by wasmtime 50.0.1!)
  const commonTypesSection = encodeSection(1, [
    7,
    0x60, 0x00, 0x01, 0x7f,                   // 0: (func (result i32))
    0x5d, 0x00,                               // 1: (cont 0)
    0x60, 0x01, 0x7f, 0x01, 0x7f,             // 2: (func (param i32) (result i32))
    0x5d, 0x02,                               // 3: (cont 2)
    0x60, 0x01, 0x63, 0x03, 0x01, 0x7f,       // 4: (func (param (ref null 3)) (result i32))
    0x5d, 0x04,                               // 5: (cont 4)
    0x60, 0x00, 0x00,                         // 6: (func)
  ]);
  const commonFuncSection = encodeSection(3, [1, 0x00]);
  const commonTagSection = encodeSection(13, [
    3,
    0x00, 0x02, // tag 0: (param i32) (result i32)
    0x00, 0x06, // tag 1: () -> ()
    0x00, 0x00, // tag 2: () -> (result i32)
  ]);
  const commonElemSection = encodeSection(9, [1, 0x03, 0x00, 1, 0x00]);

  const opcodeSpecs = [
    {
      opcode: 0xe0,
      hex: '0xe0',
      mnemonic: 'cont.new',
      immediates: '$ct_type_idx (0x01)',
      specValid: true,
      body: encodeFuncBody([0], [0xd2, 0x00, 0xe0, 0x01, 0x1a, 0x41, 0x01]),
    },
    {
      opcode: 0xe1,
      hex: '0xe1',
      mnemonic: 'cont.bind',
      immediates: '$src_ct (0x03), $dst_ct (0x01)',
      specValid: true,
      body: encodeFuncBody([0], [0x41, 0x07, 0xd0, 0x03, 0xe1, 0x03, 0x01, 0x1a, 0x41, 0x01]),
    },
    {
      opcode: 0xe2,
      hex: '0xe2',
      mnemonic: 'suspend',
      immediates: '$tag_idx (0x00)',
      specValid: true,
      body: encodeFuncBody([0], [0x41, 0x0a, 0xe2, 0x00]),
    },
    {
      opcode: 0xe3,
      hex: '0xe3',
      mnemonic: 'resume',
      immediates: '$ct_idx (0x01), vec(on_clause) (0x00)',
      specValid: true,
      body: encodeFuncBody([0], [0xd0, 0x01, 0xe3, 0x01, 0x00]),
    },
    {
      opcode: 0xe4,
      hex: '0xe4',
      mnemonic: 'resume_throw',
      immediates: '$ct_idx (0x01), $tag_idx (0x01), vec(on_clause) (0x00)',
      specValid: true,
      body: encodeFuncBody([0], [0xd0, 0x01, 0xe4, 0x01, 0x01, 0x00]),
    },
    {
      opcode: 0xe5,
      hex: '0xe5',
      mnemonic: 'resume_throw_ref',
      immediates: '$ct_idx (0x01), vec(on_clause) (0x00)',
      specValid: true,
      body: encodeFuncBody([0], [0xd0, 0x69, 0xd0, 0x01, 0xe5, 0x01, 0x00]),
    },
    {
      opcode: 0xe6,
      hex: '0xe6',
      mnemonic: 'switch',
      immediates: '$ct_idx (0x05), $tag_idx (0x02)',
      specValid: true,
      body: encodeFuncBody([0], [0xd0, 0x05, 0xe6, 0x05, 0x02]),
    },
  ];

  // Also add reserved 0xe7..0xef range
  for (let op = 0xe7; op <= 0xef; op++) {
    opcodeSpecs.push({
      opcode: op,
      hex: '0x' + op.toString(16),
      mnemonic: `reserved_0x${op.toString(16)}`,
      immediates: 'none',
      specValid: false,
      body: encodeFuncBody([0], [op, 0x41, 0x00]),
    });
  }

  const opcodeMatrixResults = opcodeSpecs.map((spec) => {
    const wasmBytes = encodeWasmModule([
      commonTypesSection,
      commonFuncSection,
      commonTagSection,
      commonElemSection,
      encodeSection(10, [1, ...spec.body]),
    ]);
    const v8Result = probeBytesInV8(wasmBytes, wasmfxFlags);

    // Also test Wasmtime 50.0.1 x86_64 compilation on the exact same binary
    const wasmPath = path.join(WORK_DIR, `opcode_${spec.hex}.wasm`);
    const cwasmPath = path.join(WORK_DIR, `opcode_${spec.hex}.cwasm`);
    fs.writeFileSync(wasmPath, wasmBytes);
    let wasmtimeX64Compiled = false;
    let wasmtimeError = null;
    let cwasmSizeBytes = 0;
    const wt = spawnSync(
      WASMTIME_BIN,
      [
        'compile',
        '--target',
        'x86_64-unknown-linux-gnu',
        '-W',
        'stack-switching=y',
        '-W',
        'exceptions=y',
        '-W',
        'function-references=y',
        wasmPath,
        '-o',
        cwasmPath,
      ],
      { env: { ...process.env, TMPDIR: TMP_ROOT }, encoding: 'utf8' }
    );
    if (wt.status === 0 && fs.existsSync(cwasmPath)) {
      wasmtimeX64Compiled = true;
      cwasmSizeBytes = fs.statSync(cwasmPath).size;
    } else {
      wasmtimeError = (wt.stderr || '').trim().split('\n').pop();
    }

    return {
      opcode: spec.hex,
      mnemonic: spec.mnemonic,
      immediates: spec.immediates,
      specDefinedInWasmFX: spec.specValid,
      v8ValidateWithWasmFX: v8Result.valid,
      v8CompileError: v8Result.compileError,
      wasmtime50X64Compiled: wasmtimeX64Compiled,
      wasmtime50CwasmBytes: cwasmSizeBytes,
      wasmtime50Diagnostic: wasmtimeError,
    };
  });

  return {
    nodeVersion: process.version,
    v8Version: process.versions.v8,
    flagsTested: wasmfxFlags,
    typeSystemMatrix: typeMatrixResults,
    opcodeMatrix: opcodeMatrixResults,
  };
}

// ---------------------------------------------------------------------------
// PART 2: Wasmtime 50.0.1 (`-W stack-switching=y`) Verification
// ---------------------------------------------------------------------------

function runPart2WasmtimeVerification() {
  const versionOut = execFileSync(WASMTIME_BIN, ['--version'], {
    env: { ...process.env, TMPDIR: TMP_ROOT },
    encoding: 'utf8',
  }).trim();

  // Complete WasmFX program exercising all continuation instructions:
  // cont.new, cont.bind, suspend, resume (with both (on $tag $label) and (on $tag switch)),
  // resume_throw, and switch.
  const watSource = `(module
  (type $ft0 (func (result i32)))
  (type $ct0 (cont $ft0))
  (type $ft1 (func (param i32) (result i32)))
  (type $ct1 (cont $ft1))
  (type $ft_sw (func (param (ref null $ct1)) (result i32)))
  (type $ct_sw (cont $ft_sw))

  (tag $yield (param i32) (result i32))
  (tag $abort)
  (tag $sw_tag (result i32))

  (func $worker_arg (param $x i32) (result i32)
    (i32.add
      (local.get $x)
      (suspend $yield (i32.const 10))))
  (elem declare func $worker_arg)

  (func $test_cont_new_bind_suspend_resume (export "test_basic") (result i32)
    (local $yielded i32)
    (local $k0 (ref null $ct0))
    (local $k1 (ref null $ct1))
    (local.set $k0
      (cont.bind $ct1 $ct0
        (i32.const 100)
        (cont.new $ct1 (ref.func $worker_arg))))
    (block $on_yield (result i32 (ref $ct1))
      (resume $ct0 (on $yield $on_yield) (on $sw_tag switch)
        (local.get $k0))
      (return))
    (local.set $k1)
    (local.set $yielded)
    (resume $ct1
      (i32.mul (local.get $yielded) (i32.const 2))
      (local.get $k1)))

  (func $test_resume_throw (export "test_throw") (param $k (ref null $ct0)) (result i32)
    (resume_throw $ct0 $abort (local.get $k)))

  (func $test_switch (export "test_switch") (param $target (ref null $ct_sw)) (result i32)
    (switch $ct_sw $sw_tag (local.get $target)))
)
`;

  const watPath = path.join(WORK_DIR, 'wasmfx_full.wat');
  const cwasmX64Path = path.join(WORK_DIR, 'wasmfx_full_x86_64.cwasm');
  const cwasmArm64Path = path.join(WORK_DIR, 'wasmfx_full_aarch64.cwasm');
  fs.writeFileSync(watPath, watSource);

  // 1. Compile for x86_64-unknown-linux-gnu
  const t0 = process.hrtime.bigint();
  const compileX64 = spawnSync(
    WASMTIME_BIN,
    [
      'compile',
      '--target',
      'x86_64-unknown-linux-gnu',
      '-W',
      'stack-switching=y',
      '-W',
      'exceptions=y',
      '-W',
      'function-references=y',
      watPath,
      '-o',
      cwasmX64Path,
    ],
    { env: { ...process.env, TMPDIR: TMP_ROOT }, encoding: 'utf8' }
  );
  const compileX64Ms = Number(process.hrtime.bigint() - t0) / 1e6;
  const cwasmSize = fs.existsSync(cwasmX64Path) ? fs.statSync(cwasmX64Path).size : 0;

  // Inspect ELF symbol table using objdump -t
  const symOut = execFileSync('objdump', ['-t', cwasmX64Path], {
    env: { ...process.env, TMPDIR: TMP_ROOT },
    encoding: 'utf8',
  });
  const symbols = symOut
    .split('\n')
    .filter((line) => line.includes('.text'))
    .map((line) => {
      const parts = line.trim().split(/\s+/);
      const name = parts[parts.length - 1];
      const sizeHex = parts[parts.length - 2];
      return { name, sizeBytes: parseInt(sizeHex, 16) };
    });

  // Inspect generated x86_64 machine code using `wasmtime objdump`
  const objdumpOut = execFileSync(WASMTIME_BIN, ['objdump', cwasmX64Path], {
    env: { ...process.env, TMPDIR: TMP_ROOT },
    encoding: 'utf8',
  });
  const objdumpLines = objdumpOut.split('\n');
  // Extract the inline %rsp / %rbp / %rip switch sequence from worker_arg (suspend)
  const rspSwitchIdx = objdumpLines.findIndex((l) => l.includes('movq    %rsp, (%rcx)'));
  const inlineStackSwitchSnippet =
    rspSwitchIdx >= 0
      ? objdumpLines
          .slice(Math.max(0, rspSwitchIdx - 2), Math.min(objdumpLines.length, rspSwitchIdx + 10))
          .map((s) => s.trim())
      : [];

  // 2. Test compiling for aarch64-unknown-linux-gnu
  const compileArm64 = spawnSync(
    WASMTIME_BIN,
    [
      'compile',
      '--target',
      'aarch64-unknown-linux-gnu',
      '-W',
      'stack-switching=y',
      '-W',
      'exceptions=y',
      '-W',
      'function-references=y',
      watPath,
      '-o',
      cwasmArm64Path,
    ],
    { env: { ...process.env, TMPDIR: TMP_ROOT }, encoding: 'utf8' }
  );

  // 3. Test running on the aarch64 host
  const runArm64 = spawnSync(
    WASMTIME_BIN,
    [
      'run',
      '-W',
      'stack-switching=y',
      '-W',
      'exceptions=y',
      '-W',
      'function-references=y',
      '--invoke',
      'test_basic',
      watPath,
    ],
    { env: { ...process.env, TMPDIR: TMP_ROOT }, encoding: 'utf8' }
  );

  return {
    wasmtimeVersion: versionOut,
    hostArch: process.arch,
    x86_64AotCompilation: {
      target: 'x86_64-unknown-linux-gnu',
      flags: ['-W stack-switching=y', '-W exceptions=y', '-W function-references=y'],
      succeeded: compileX64.status === 0,
      compileTimeMs: +compileX64Ms.toFixed(2),
      cwasmArtifactBytes: cwasmSize,
      symbols,
      inlineStackSwitchAssembly: inlineStackSwitchSnippet,
    },
    aarch64Compilation: {
      target: 'aarch64-unknown-linux-gnu',
      succeeded: compileArm64.status === 0,
      diagnostic: (compileArm64.stderr || '').trim(),
    },
    aarch64HostExecution: {
      succeeded: runArm64.status === 0,
      diagnostic: (runArm64.stderr || '').trim(),
    },
  };
}

// ---------------------------------------------------------------------------
// PART 3: Executable Dual-Stack (`__stack_pointer` / `global[0]`) Prototype
// ---------------------------------------------------------------------------

/**
 * Transforms a Wasm binary to also export `global[0]` (`__stack_pointer`) as `"__stack_pointer"`,
 * enabling direct `WebAssembly.Global` `.value` inspection and context-switching from JS.
 */
function exportGlobal0AsStackPointer(wasmBytes) {
  try {
    const mod = new WebAssembly.Module(wasmBytes);
    if (WebAssembly.Module.exports(mod).some((e) => e.name === '__stack_pointer')) {
      return new Uint8Array(wasmBytes);
    }
  } catch {}
  let offset = 8;
  const out = [Buffer.from(wasmBytes.slice(0, 8))];
  while (offset < wasmBytes.length) {
    const id = wasmBytes[offset++];
    let len = 0;
    let shift = 0;
    while (true) {
      const b = wasmBytes[offset++];
      len |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) break;
      shift += 7;
    }
    const payload = Buffer.from(wasmBytes.slice(offset, offset + len));
    offset += len;
    if (id === 7) {
      let pOff = 0;
      let count = 0;
      let s = 0;
      while (true) {
        const b = payload[pOff++];
        count |= (b & 0x7f) << s;
        if ((b & 0x80) === 0) break;
        s += 7;
      }
      const name = Buffer.from('__stack_pointer', 'utf8');
      const entry = Buffer.concat([
        Buffer.from([name.length]),
        name,
        Buffer.from([0x03, 0x00]), // export kind 0x03 = global, index 0x00 = global[0]
      ]);
      const newPayload = Buffer.concat([
        Buffer.from(uleb128(count + 1)),
        payload.slice(pOff),
        entry,
      ]);
      out.push(Buffer.from([id, ...uleb128(newPayload.length)]), newPayload);
    } else {
      out.push(Buffer.from([id, ...uleb128(len)]), payload);
    }
  }
  return new Uint8Array(Buffer.concat(out));
}

/**
 * Builds a synthetic Wasm binary with a mutable `global[0]` (`__stack_pointer`) and a recursive
 * `fiberTask(fiber_id, depth)` function that allocates a 64-byte frame on `global[0]` in linear
 * memory, writes a canary, calls `env.hostAsyncYield(fiber_id, depth, sp)`, recurses, and checks
 * the canary after resumption before restoring `global[0]`.
 */
function buildSyntheticDualStackWasm() {
  return encodeWasmModule([
    // Type section:
    // 0: (func (param i32 i32 i32) (result i32)) -> hostAsyncYield
    // 1: (func (param i32 i32) (result i32))     -> fiberTask
    encodeSection(1, [
      2,
      0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
      0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    ]),
    // Import section: env.hostAsyncYield (type 0)
    encodeSection(2, [
      1,
      ...encodeString('env'),
      ...encodeString('hostAsyncYield'),
      0x00,
      0x00,
    ]),
    // Function section: func 1 (fiberTask, type 1)
    encodeSection(3, [1, 0x01]),
    // Memory section: 32 pages (2 MB)
    encodeSection(5, [1, 0x00, 32]),
    // Global section: global 0 = mutable i32, init 65536 (64 KB default stack top)
    encodeSection(6, [1, 0x7f, 0x01, 0x41, ...sleb128(65536), 0x0b]),
    // Export section: memory, __stack_pointer, fiberTask
    encodeSection(7, [
      3,
      ...encodeString('memory'), 0x02, 0x00,
      ...encodeString('__stack_pointer'), 0x03, 0x00,
      ...encodeString('fiberTask'), 0x00, 0x01,
    ]),
    // Code section:
    // params: 0 = fiber_id, 1 = depth
    // locals: 2 = sp (i32), 3 = expected_canary (i32), 4 = result (i32)
    encodeSection(10, [
      1,
      ...encodeFuncBody(
        [1, 3, 0x7f],
        [
          // sp = global[0] - 64; global[0] = sp
          0x23, 0x00,
          0x41, 0x40,
          0x6b,
          0x22, 0x02,
          0x24, 0x00,
          // expected_canary = (fiber_id << 16) ^ depth ^ 0x5a5a1234
          0x20, 0x00,
          0x41, 0x10,
          0x74,
          0x20, 0x01,
          0x73,
          0x41, ...sleb128(0x5a5a1234),
          0x73,
          0x21, 0x03,
          // mem32[sp] = expected_canary; mem32[sp + 60] = expected_canary
          0x20, 0x02,
          0x20, 0x03,
          0x36, 0x02, 0x00,
          0x20, 0x02,
          0x20, 0x03,
          0x36, 0x02, 0x3c,
          // call hostAsyncYield(fiber_id, depth, sp) -> drop
          0x20, 0x00,
          0x20, 0x01,
          0x20, 0x02,
          0x10, 0x00,
          0x1a,
          // if (depth > 1) { res = fiberTask(fiber_id, depth - 1); if (res < 0) { global[0] = sp + 64; return -1; } }
          0x20, 0x01,
          0x41, 0x01,
          0x4a,
          0x04, 0x40,
            0x20, 0x00,
            0x20, 0x01,
            0x41, 0x01,
            0x6b,
            0x10, 0x01,
            0x22, 0x04,
            0x41, 0x00,
            0x48,
            0x04, 0x40,
              0x20, 0x02,
              0x41, 0x40,
              0x6a,
              0x24, 0x00,
              0x41, 0x7f, // -1
              0x0f,
            0x0b,
          0x0b,
          // Verify mem32[sp] == expected_canary && mem32[sp + 60] == expected_canary
          0x20, 0x02,
          0x28, 0x02, 0x00,
          0x20, 0x03,
          0x47,
          0x20, 0x02,
          0x28, 0x02, 0x3c,
          0x20, 0x03,
          0x47,
          0x72,
          0x04, 0x40,
            0x20, 0x02,
            0x41, 0x40,
            0x6a,
            0x24, 0x00,
            0x41, 0x7f, // -1 (corruption!)
            0x0f,
          0x0b,
          // Epilogue: global[0] = sp + 64; return result + 1
          0x20, 0x02,
          0x41, 0x40,
          0x6a,
          0x24, 0x00,
          0x20, 0x04,
          0x41, 0x01,
          0x6a,
        ]
      ),
    ]),
  ]);
}

/**
 * Compiles the real Zig dual-stack fiber benchmark using `wazig build-exe`
 * (`-target wasm32-wasi -O ReleaseSmall -fno-entry -rdynamic`).
 */
function compileRealWazigDualStackModule() {
  const zigSource = `const std = @import("std");

extern "env" fn hostAsyncYield(fiber_id: u32, depth: u32, buf_ptr: usize) u32;

const STACK_POOL_SIZE: usize = 64 * 16384;
var stack_pool: [STACK_POOL_SIZE]u8 align(16) = @splat(0);
var stack_bump: usize = 0;

export fn resetStackPool() void {
    stack_bump = 0;
}

export fn allocStack(size: usize) ?[*]align(16) u8 {
    const aligned_size = (size + 15) & ~@as(usize, 15);
    if (stack_bump + aligned_size > STACK_POOL_SIZE) return null;
    const ptr: [*]align(16) u8 = @alignCast(stack_pool[stack_bump..].ptr);
    stack_bump += aligned_size;
    return ptr;
}

export fn freeStack(ptr: [*]align(16) u8, size: usize) void {
    _ = ptr;
    _ = size;
}

inline fn computeCanary(fiber_id: u32, depth: u32, word_idx: u32) u32 {
    return (fiber_id *% 0x9e3779b9) ^ (depth *% 0x85ebca6b) ^ (word_idx *% 0x01010101) ^ 0xa5a55a5a;
}

export fn fiberTask(fiber_id: u32, depth: u32) i32 {
    var local_buf: [16]u32 align(16) = undefined;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        local_buf[i] = computeCanary(fiber_id, depth, i);
    }
    std.mem.doNotOptimizeAway(&local_buf);

    const buf_addr: usize = @intFromPtr(&local_buf[0]);
    const resumed_val = hostAsyncYield(fiber_id, depth, buf_addr);

    var child_checksum: i32 = 0;
    if (depth > 1) {
        child_checksum = fiberTask(fiber_id, depth - 1);
        if (child_checksum < 0) return -1;
    }

    std.mem.doNotOptimizeAway(&local_buf);
    var j: u32 = 0;
    var frame_xor: u32 = resumed_val;
    while (j < 16) : (j += 1) {
        const expected = computeCanary(fiber_id, depth, j);
        const actual = local_buf[j];
        if (actual != expected) {
            return -1;
        }
        frame_xor ^= actual;
    }

    const safe_positive: i32 = @intCast((frame_xor & 0x3fff) + 1);
    return child_checksum + safe_positive;
}
`;

  const zigFile = 'dual_stack_fiber.zig';
  const wasmFile = 'dual_stack_fiber.wasm';
  fs.writeFileSync(path.join(WORK_DIR, zigFile), zigSource);

  const globalCacheRel = 'zig-global';
  const localCacheRel = 'zig-local';
  fs.mkdirSync(path.join(WORK_DIR, globalCacheRel), { recursive: true });
  fs.mkdirSync(path.join(WORK_DIR, localCacheRel), { recursive: true });

  const t0 = process.hrtime.bigint();
  execFileSync(
    WAZIG_BIN,
    [
      'build-exe',
      zigFile,
      '-target',
      'wasm32-wasi',
      '-O',
      'ReleaseSmall',
      '-fno-entry',
      '-rdynamic',
      `-femit-bin=${wasmFile}`,
    ],
    {
      cwd: WORK_DIR,
      env: {
        ...process.env,
        TMPDIR: '.',
        ZIG_GLOBAL_CACHE_DIR: globalCacheRel,
        ZIG_LOCAL_CACHE_DIR: localCacheRel,
      },
      encoding: 'utf8',
    }
  );
  const compileMs = Number(process.hrtime.bigint() - t0) / 1e6;
  const rawWasmBytes = fs.readFileSync(path.join(WORK_DIR, wasmFile));
  const patchedWasmBytes = exportGlobal0AsStackPointer(rawWasmBytes);
  return {
    rawWasmSizeBytes: rawWasmBytes.length,
    patchedWasmSizeBytes: patchedWasmBytes.length,
    compileTimeMs: +compileMs.toFixed(2),
    patchedWasmBytes,
  };
}

/**
 * Runs the child-process JSPI dual-stack experiment under
 * `--experimental-wasm-growable-stacks --wasm-stack-switching-stack-size=4`.
 */
function runDualStackChildExperiment(wasmBytes, label, hasAllocStack) {
  const hex = Buffer.from(wasmBytes).toString('hex');
  const childScript = `
    const wasmBytes = Uint8Array.from(Buffer.from(${JSON.stringify(hex)}, 'hex'));
    const hasAllocStack = ${JSON.stringify(hasAllocStack)};
    const mod = new WebAssembly.Module(wasmBytes);

    async function runExperiment(switchStackPointer, numFibers = 50, maxDepth = 20) {
      let exportsRef = null;
      const fiberStates = new Map();
      const pendingQueue = [];
      const depth20Addresses = [];
      const addressToFibers = new Map();
      let totalSuspensions = 0;
      let pumpScheduled = false;

      function schedulePump() {
        if (pumpScheduled) return;
        pumpScheduled = true;
        queueMicrotask(pumpNext);
      }

      function pumpNext() {
        pumpScheduled = false;
        if (pendingQueue.length === 0) return;
        // Deterministic out-of-order selection across all suspended continuations
        const pickIdx = pendingQueue.length > 1
          ? ((totalSuspensions * 17 + 7) % pendingQueue.length)
          : 0;
        const item = pendingQueue.splice(pickIdx, 1)[0];
        if (switchStackPointer) {
          exportsRef.__stack_pointer.value = fiberStates.get(item.fiberId).sp;
        }
        item.resolve((item.fiberId * 31 + item.depth * 13) >>> 0);
        if (pendingQueue.length > 0) {
          schedulePump();
        }
      }

      const hostAsyncYield = new WebAssembly.Suspending((fiberId, depth, bufPtr) => {
        totalSuspensions++;
        const addr = bufPtr >>> 0;
        let owners = addressToFibers.get(addr);
        if (!owners) {
          owners = new Set();
          addressToFibers.set(addr, owners);
        }
        owners.add(fiberId);
        if (depth === maxDepth) {
          depth20Addresses.push({ fiberId, bufPtr: addr });
        }
        if (switchStackPointer) {
          fiberStates.get(fiberId).sp = exportsRef.__stack_pointer.value;
        }
        return new Promise((resolve) => {
          pendingQueue.push({ fiberId, depth, bufPtr: addr, resolve });
          schedulePump();
        });
      });

      const instance = new WebAssembly.Instance(mod, { env: { hostAsyncYield } });
      exportsRef = instance.exports;
      if (exportsRef.resetStackPool) {
        exportsRef.resetStackPool();
      }
      const initialDefaultSp = exportsRef.__stack_pointer.value;
      const promisingFiberTask = WebAssembly.promising(exportsRef.fiberTask);

      const t0 = process.hrtime.bigint();
      const promises = [];
      for (let f = 1; f <= numFibers; f++) {
        if (switchStackPointer) {
          const stackSize = 16384;
          const base = hasAllocStack
            ? exportsRef.allocStack(stackSize)
            : (65536 + f * stackSize);
          const top = base + stackSize;
          fiberStates.set(f, { base, top, sp: top });
          exportsRef.__stack_pointer.value = top;
        }
        const p = promisingFiberTask(f, maxDepth).then((res) => {
          if (switchStackPointer && hasAllocStack) {
            const st = fiberStates.get(f);
            exportsRef.freeStack(st.base, 16384);
          }
          return { fiberId: f, result: res };
        });
        promises.push(p);
      }
      if (switchStackPointer) {
        exportsRef.__stack_pointer.value = initialDefaultSp;
      }

      const results = await Promise.all(promises);
      const elapsedNs = Number(process.hrtime.bigint() - t0);

      const corruptedFibers = results.filter((r) => r.result < 0).length;
      const validFibers = results.filter((r) => r.result > 0).length;
      let collidingAddresses = 0;
      const sampleCollisions = [];
      for (const [addr, owners] of addressToFibers.entries()) {
        if (owners.size > 1) {
          collidingAddresses++;
          if (sampleCollisions.length < 5) {
            sampleCollisions.push({
              bufPtr: '0x' + addr.toString(16),
              fibersSharingAddress: Array.from(owners).slice(0, 8),
            });
          }
        }
      }

      return {
        mode: switchStackPointer ? 'per_continuation_stack_pointer_switched' : 'shared_stack_pointer_default_jspi',
        switchStackPointer,
        numFibers,
        maxDepth,
        totalSuspensions,
        validFibers,
        corruptedFibers,
        corruptionRatePct: +((corruptedFibers / numFibers) * 100).toFixed(1),
        uniqueFrameAddresses: addressToFibers.size,
        expectedFrameAddresses: numFibers * maxDepth,
        collidingAddresses,
        sampleCollisions,
        sampleDepth20Addresses: depth20Addresses.slice(0, 6).map((x) => ({
          fiberId: x.fiberId,
          bufPtrHex: '0x' + x.bufPtr.toString(16),
          bufPtrDec: x.bufPtr,
        })),
        totalElapsedMs: +(elapsedNs / 1e6).toFixed(3),
        nsPerContinuationSwitch: Math.round(elapsedNs / totalSuspensions),
      };
    }

    // Microbenchmark raw global[0] (__stack_pointer.value) save + restore cost
    function benchmarkRawGlobal0Switch(iterations = 500000) {
      const instance = new WebAssembly.Instance(mod, { env: { hostAsyncYield: () => 0 } });
      const spGlobal = instance.exports.__stack_pointer;
      const baseSp = spGlobal.value;
      const altSp = baseSp - 16384;
      // Warmup
      for (let i = 0; i < 10000; i++) {
        const saved = spGlobal.value;
        spGlobal.value = altSp;
        spGlobal.value = saved;
      }
      const t0 = process.hrtime.bigint();
      let acc = 0;
      for (let i = 0; i < iterations; i++) {
        const saved = spGlobal.value;
        spGlobal.value = (i & 1) ? altSp : baseSp;
        acc ^= saved;
      }
      spGlobal.value = baseSp;
      const elapsedNs = Number(process.hrtime.bigint() - t0);
      return {
        iterations,
        totalMs: +(elapsedNs / 1e6).toFixed(3),
        nsPerSaveRestorePair: +(elapsedNs / iterations).toFixed(2),
        checksum: acc,
      };
    }

    (async () => {
      const sharedMode = await runExperiment(false, 50, 20);
      const switchedMode = await runExperiment(true, 50, 20);
      // Warmed throughput comparison (20 iterations of 50x20 = 20,000 switches)
      const benchRuns = 20;
      const tShared0 = process.hrtime.bigint();
      for (let i = 0; i < benchRuns; i++) await runExperiment(false, 50, 20);
      const sharedAvgNs = Math.round(Number(process.hrtime.bigint() - tShared0) / (benchRuns * 1000));

      const tSwitched0 = process.hrtime.bigint();
      for (let i = 0; i < benchRuns; i++) await runExperiment(true, 50, 20);
      const switchedAvgNs = Math.round(Number(process.hrtime.bigint() - tSwitched0) / (benchRuns * 1000));

      const rawGlobalSwitch = benchmarkRawGlobal0Switch(500000);
      console.log(JSON.stringify({
        label: ${JSON.stringify(label)},
        sharedMode,
        switchedMode,
        warmedThroughput20kSwitches: {
          sharedNsPerSwitch: sharedAvgNs,
          switchedNsPerSwitch: switchedAvgNs,
          overheadNsPerSwitch: switchedAvgNs - sharedAvgNs,
        },
        rawGlobal0SaveRestoreBenchmark: rawGlobalSwitch,
      }));
    })();
  `;

  const res = runNodeEval(
    ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4'],
    childScript
  );
  if (res.status !== 0) {
    throw new Error(`Dual-stack child experiment (${label}) failed: ${res.stderr || res.stdout}`);
  }
  return JSON.parse(res.stdout);
}

function runPart3DualStackPrototype() {
  const wazigVersion = execFileSync(WAZIG_BIN, ['version'], {
    env: { ...process.env, TMPDIR: TMP_ROOT },
    encoding: 'utf8',
  }).trim();

  // 1. Real wazig-compiled Zig module
  const wazigBuild = compileRealWazigDualStackModule();
  const realZigExperiment = runDualStackChildExperiment(
    wazigBuild.patchedWasmBytes,
    'wazig_real_zig_module',
    true
  );

  // 2. Synthetic handcrafted Wasm binary module
  const syntheticBytes = buildSyntheticDualStackWasm();
  const syntheticExperiment = runDualStackChildExperiment(
    syntheticBytes,
    'synthetic_wasm_binary',
    false
  );

  return {
    wazigVersion,
    zigCompilationFlags: ['-target wasm32-wasi', '-O ReleaseSmall', '-fno-entry', '-rdynamic'],
    v8RuntimeFlags: ['--experimental-wasm-growable-stacks', '--wasm-stack-switching-stack-size=4'],
    wazigModuleSizes: {
      rawBytes: wazigBuild.rawWasmSizeBytes,
      withExportedStackPointerBytes: wazigBuild.patchedWasmSizeBytes,
      compileTimeMs: wazigBuild.compileTimeMs,
    },
    realWazigZigModule: realZigExperiment,
    syntheticWasmModule: syntheticExperiment,
  };
}

// ---------------------------------------------------------------------------
// Main Execution & Console Reporting
// ---------------------------------------------------------------------------

function main() {
  fs.mkdirSync(WORK_DIR, { recursive: true });
  try {
    console.log('================================================================================');
    console.log('Issue #14 WasmFX (Typed Continuations) & Dual-Stack (__stack_pointer) Prototype');
    console.log('================================================================================\n');

    const part1 = runPart1V8WasmFXMatrix();
    console.log('--- PART 1A: V8 13.6 (`--experimental-wasm-wasmfx`) Type-System Matrix ---');
    console.table(
      part1.typeSystemMatrix.map((t) => ({
        Test: t.id,
        'No Flag Validate': t.withoutWasmFXFlag.valid,
        'With Flag Validate': t.withWasmFXFlag.valid,
        'With Flag Compile': t.withWasmFXFlag.compiled,
        'Instantiate & Run': t.instantiationWithWasmFXFlag.instantiated
          ? `OK (ret=${t.instantiationWithWasmFXFlag.returnValue})`
          : `V8_Fatal (${t.instantiationWithWasmFXFlag.fatalError})`,
      }))
    );

    console.log('\n--- PART 1B: WasmFX Instruction Opcode Matrix (0xe0..0xef) in V8 13.6 vs Wasmtime 50.0.1 ---');
    console.table(
      part1.opcodeMatrix.slice(0, 9).map((o) => ({
        Opcode: o.opcode,
        Mnemonic: o.mnemonic,
        'Spec Valid': o.specDefinedInWasmFX,
        'V8 13.6 Validate': o.v8ValidateWithWasmFX,
        'V8 13.6 CompileError': o.v8CompileError ? o.v8CompileError.replace('WebAssembly.Module(): ', '') : 'OK',
        'Wasmtime 50.0.1 x86_64 AOT': o.wasmtime50X64Compiled ? `OK (${o.wasmtime50CwasmBytes} B)` : 'FAIL',
      }))
    );

    const part2 = runPart2WasmtimeVerification();
    console.log('\n--- PART 2: Wasmtime 50.0.1 (`-W stack-switching=y`) Target & ELF Symbol Summary ---');
    console.table([
      {
        Target: part2.x86_64AotCompilation.target,
        Mode: 'wasmtime compile (AOT)',
        Succeeded: part2.x86_64AotCompilation.succeeded,
        ArtifactBytes: part2.x86_64AotCompilation.cwasmArtifactBytes,
        Detail: `${part2.x86_64AotCompilation.symbols.length} ELF .text symbols (${part2.x86_64AotCompilation.compileTimeMs} ms)`,
      },
      {
        Target: part2.aarch64Compilation.target,
        Mode: 'wasmtime compile (AOT)',
        Succeeded: part2.aarch64Compilation.succeeded,
        ArtifactBytes: 0,
        Detail: part2.aarch64Compilation.diagnostic,
      },
      {
        Target: `host (${part2.hostArch})`,
        Mode: 'wasmtime run (JIT)',
        Succeeded: part2.aarch64HostExecution.succeeded,
        ArtifactBytes: 0,
        Detail: part2.aarch64HostExecution.diagnostic,
      },
    ]);
    console.log('\nWasmtime 50.0.1 x86_64 inline stack-switch machine code (`wasmtime objdump`):');
    for (const line of part2.x86_64AotCompilation.inlineStackSwitchAssembly) {
      console.log('  ' + line);
    }

    const part3 = runPart3DualStackPrototype();
    console.log('\n--- PART 3: Dual-Stack (`__stack_pointer` / `global[0]`) Context-Switching (50 Fibers x Depth 20 = 1,000 Switches) ---');
    console.table([
      {
        Module: 'Real wazig Zig (.wasm)',
        Mode: '1. Shared __stack_pointer (Default JSPI)',
        'Valid Fibers': `${part3.realWazigZigModule.sharedMode.validFibers} / ${part3.realWazigZigModule.sharedMode.numFibers}`,
        'Corrupted Fibers': `${part3.realWazigZigModule.sharedMode.corruptedFibers} (${part3.realWazigZigModule.sharedMode.corruptionRatePct}%)`,
        'Unique Frame Addrs': `${part3.realWazigZigModule.sharedMode.uniqueFrameAddresses} / ${part3.realWazigZigModule.sharedMode.expectedFrameAddresses}`,
        'Colliding Addrs': part3.realWazigZigModule.sharedMode.collidingAddresses,
        'Warmed ns/switch': part3.realWazigZigModule.warmedThroughput20kSwitches.sharedNsPerSwitch,
      },
      {
        Module: 'Real wazig Zig (.wasm)',
        Mode: '2. Per-Continuation __stack_pointer Switched',
        'Valid Fibers': `${part3.realWazigZigModule.switchedMode.validFibers} / ${part3.realWazigZigModule.switchedMode.numFibers}`,
        'Corrupted Fibers': `${part3.realWazigZigModule.switchedMode.corruptedFibers} (${part3.realWazigZigModule.switchedMode.corruptionRatePct}%)`,
        'Unique Frame Addrs': `${part3.realWazigZigModule.switchedMode.uniqueFrameAddresses} / ${part3.realWazigZigModule.switchedMode.expectedFrameAddresses}`,
        'Colliding Addrs': part3.realWazigZigModule.switchedMode.collidingAddresses,
        'Warmed ns/switch': part3.realWazigZigModule.warmedThroughput20kSwitches.switchedNsPerSwitch,
      },
      {
        Module: 'Synthetic Wasm Binary',
        Mode: '1. Shared __stack_pointer (Default JSPI)',
        'Valid Fibers': `${part3.syntheticWasmModule.sharedMode.validFibers} / ${part3.syntheticWasmModule.sharedMode.numFibers}`,
        'Corrupted Fibers': `${part3.syntheticWasmModule.sharedMode.corruptedFibers} (${part3.syntheticWasmModule.sharedMode.corruptionRatePct}%)`,
        'Unique Frame Addrs': `${part3.syntheticWasmModule.sharedMode.uniqueFrameAddresses} / ${part3.syntheticWasmModule.sharedMode.expectedFrameAddresses}`,
        'Colliding Addrs': part3.syntheticWasmModule.sharedMode.collidingAddresses,
        'Warmed ns/switch': part3.syntheticWasmModule.warmedThroughput20kSwitches.sharedNsPerSwitch,
      },
      {
        Module: 'Synthetic Wasm Binary',
        Mode: '2. Per-Continuation __stack_pointer Switched',
        'Valid Fibers': `${part3.syntheticWasmModule.switchedMode.validFibers} / ${part3.syntheticWasmModule.switchedMode.numFibers}`,
        'Corrupted Fibers': `${part3.syntheticWasmModule.switchedMode.corruptedFibers} (${part3.syntheticWasmModule.switchedMode.corruptionRatePct}%)`,
        'Unique Frame Addrs': `${part3.syntheticWasmModule.switchedMode.uniqueFrameAddresses} / ${part3.syntheticWasmModule.switchedMode.expectedFrameAddresses}`,
        'Colliding Addrs': part3.syntheticWasmModule.switchedMode.collidingAddresses,
        'Warmed ns/switch': part3.syntheticWasmModule.warmedThroughput20kSwitches.switchedNsPerSwitch,
      },
    ]);
    console.log(
      `\nRaw exports.__stack_pointer.value save+restore latency (${part3.realWazigZigModule.rawGlobal0SaveRestoreBenchmark.iterations} pairs): ` +
        `${part3.realWazigZigModule.rawGlobal0SaveRestoreBenchmark.nsPerSaveRestorePair} ns/pair`
    );

    const fullResults = {
      timestamp: new Date().toISOString(),
      issue: 14,
      workstream: 'wasmfx-prototype',
      environment: {
        nodeVersion: process.version,
        v8Version: process.versions.v8,
        wasmtimeVersion: part2.wasmtimeVersion,
        wazigVersion: part3.wazigVersion,
        platform: process.platform,
        arch: process.arch,
      },
      part1_v8WasmFXMatrix: part1,
      part2_wasmtimeStackSwitching: part2,
      part3_dualStackContextSwitching: part3,
    };

    fs.writeFileSync(RESULTS_PATH, JSON.stringify(fullResults, null, 2) + '\n');
    console.log(`\nWrote structured JSON results to: ${RESULTS_PATH}`);
  } finally {
    fs.rmSync(WORK_DIR, { recursive: true, force: true });
  }
}

main();
