import { expect } from 'chai';
import { execFile } from 'child_process';
import { cpSync, existsSync, mkdirSync, rmSync } from 'fs';
import { readFile, writeFile } from 'fs/promises';
import 'mocha-skip-if';
import { dirname, join, resolve } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { promisify } from 'util';
import { compile, runWit } from '../src/compilation.js';
import { transpile } from '../src/transpilation.js';
import {
  ensureStackPointerExport,
  ObjectType,
  parseBinary,
  repackBinary,
  SectionType,
  stripUnused,
} from '../src/wasm-decoding.js';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKTREE_CACHE_DIR = resolve(__dirname, '../../.cache');
const TMP_BASE = process.env.TMPDIR || join(WORKTREE_CACHE_DIR, 'tmp');
const TMP_ROOT = join(TMP_BASE, `wit-zigar-bridge-test-${process.pid}`);
const LOCAL_CACHE_DIR = join(TMP_ROOT, 'zig-cache');
const GLOBAL_CACHE_DIR = process.env.ZIG_GLOBAL_CACHE_DIR || join(TMP_ROOT, 'zig-global-cache');
const XDG_CACHE_DIR = process.env.XDG_CACHE_HOME || join(TMP_ROOT, 'xdg-cache');
const BUILD_DIR = join(TMP_ROOT, 'wit-zigar-build');
const MODULE_OUT_DIR = join(TMP_ROOT, 'wit-zigar-modules');
const RUNTIME_SRC_DIR = resolve(__dirname, '../../zigar-runtime/src');
const LOCAL_BIN_DIR = join(process.env.HOME || '/home/g', '.local', 'bin');
if (existsSync(LOCAL_BIN_DIR) && !(process.env.PATH || '').split(':').includes(LOCAL_BIN_DIR)) {
  process.env.PATH = `${LOCAL_BIN_DIR}:${process.env.PATH || ''}`;
}
const WAZIG_BIN = existsSync(join(LOCAL_BIN_DIR, 'wazig'))
  ? join(LOCAL_BIN_DIR, 'wazig')
  : (existsSync('/d/zig/wazig/bin/wazig') ? '/d/zig/wazig/bin/wazig' : 'wazig');
const SERVICE_ZIG_PATH = fileURLToPath(new URL('./zig-samples/wit-zigar/service.zig', import.meta.url));

const prevEnv = {
  ZIG_LOCAL_CACHE_DIR: process.env.ZIG_LOCAL_CACHE_DIR,
  ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR,
  XDG_CACHE_HOME: process.env.XDG_CACHE_HOME,
  TMPDIR: process.env.TMPDIR,
};

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function transpileAndImportService(options = {}) {
  const {
    optimize = 'ReleaseSmall',
    stripWASM = optimize !== 'Debug',
    useJSPI = true,
    continuationStackSize = 8192,
    tag = `${optimize}-strip-${stripWASM}-jspi-${useJSPI}`,
  } = options;

  const { code, exports, structures, sourcePaths } = await transpile(SERVICE_ZIG_PATH, {
    optimize,
    embedWASM: true,
    stripWASM,
    useWazig: true,
    useJSPI,
    continuationStackSize,
    zigPath: WAZIG_BIN,
    buildDir: join(BUILD_DIR, tag),
  });

  const resolvedCode = code
    .replace(
      /from\s+["']zigar-runtime["']/g,
      `from ${JSON.stringify(pathToFileURL(join(RUNTIME_SRC_DIR, 'index.js')).href)}`,
    )
    .replace(
      /import\s+["']zigar-runtime\/([^"']+)["']/g,
      (_, subPath) => `import ${JSON.stringify(pathToFileURL(join(RUNTIME_SRC_DIR, subPath)).href)}`,
    );

  const mjsPath = join(MODULE_OUT_DIR, `wit-zigar-service-${tag}-${Date.now()}.mjs`);
  await writeFile(mjsPath, resolvedCode, 'utf8');
  const mod = await import(pathToFileURL(mjsPath).href);
  return { mod, code, exports, structures, sourcePaths };
}

describe('wit-zigar + zigar + wazig End-to-End Bridge (Issue #19)', function() {
  this.timeout(0);

  let serviceMod;
  let transpiledArtifacts;

  before(async function() {
    for (const dir of [ TMP_ROOT, LOCAL_CACHE_DIR, GLOBAL_CACHE_DIR, XDG_CACHE_DIR, BUILD_DIR, MODULE_OUT_DIR ]) {
      mkdirSync(dir, { recursive: true });
    }
    process.env.ZIG_LOCAL_CACHE_DIR = LOCAL_CACHE_DIR;
    process.env.ZIG_GLOBAL_CACHE_DIR = GLOBAL_CACHE_DIR;
    process.env.XDG_CACHE_HOME = XDG_CACHE_DIR;
    process.env.TMPDIR = TMP_ROOT;

    transpiledArtifacts = await transpileAndImportService({
      optimize: 'ReleaseSmall',
      stripWASM: true,
      useJSPI: true,
      continuationStackSize: 8192,
      tag: 'e2e-main',
    });
    serviceMod = transpiledArtifacts.mod;
  });

  after(async function() {
    await serviceMod?.__zigar?.abandon();
    for (const [ key, val ] of Object.entries(prevEnv)) {
      if (val === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = val;
      }
    }
    rmSync(TMP_ROOT, { recursive: true, force: true });
  });

  it('should compile service.zig with wazig in Debug and ReleaseSmall, preserving "zigar:abi" custom section and __stack_pointer export', async function() {
    for (const [ optimize, shouldStrip ] of [ [ 'Debug', false ], [ 'ReleaseSmall', true ] ]) {
      const tag = `compile-${optimize.toLowerCase()}`;
      const { outputPath } = await compile(SERVICE_ZIG_PATH, null, {
        optimize,
        arch: 'wasm32',
        platform: 'wasi',
        isWASM: true,
        useWazig: true,
        zigPath: WAZIG_BIN,
        buildDir: join(BUILD_DIR, tag),
      });
      const rawContent = await readFile(outputPath);
      const rawDV = new DataView(rawContent.buffer, rawContent.byteOffset, rawContent.byteLength);

      // Verify linksection("zigar:abi") payload ("ZGAR" v1 + "wit-zigar:service:v1") is emitted by wazig
      const rawBytes = new Uint8Array(rawDV.buffer, rawDV.byteOffset, rawDV.byteLength);
      const expectedAbiPayload = Buffer.from(
        'ZGAR\x01\x00\x07\x00\x05\x00\x00\x00wit-zigar:service:v1',
        'binary'
      );
      expect(Buffer.from(rawBytes).indexOf(expectedAbiPayload)).to.be.at.least(0);

      // Attach the "zigar:abi" Wasm custom section (as emitted by wit-zigar zigar_bridge) if not already a custom section
      const parsedRaw = parseBinary(rawDV);
      if (!parsedRaw.sections.some((s) => s.type === SectionType.Custom && s.name === 'zigar:abi')) {
        parsedRaw.sections.push({
          type: SectionType.Custom,
          name: 'zigar:abi',
          data: new DataView(
            expectedAbiPayload.buffer,
            expectedAbiPayload.byteOffset,
            expectedAbiPayload.byteLength
          ),
        });
      }
      const withCustomDV = repackBinary({
        sections: parsedRaw.sections,
        size: parsedRaw.size + 128,
      });
      const processedDV = shouldStrip ? stripUnused(withCustomDV) : ensureStackPointerExport(withCustomDV);

      const { sections } = parseBinary(processedDV);
      const abiSection = sections.find(
        (s) => s.type === SectionType.Custom && s.name === 'zigar:abi'
      );
      expect(abiSection, `"zigar:abi" custom section in ${optimize}`).to.be.an('object');
      const abiBytes = new Uint8Array(
        abiSection.data.buffer,
        abiSection.data.byteOffset,
        abiSection.data.byteLength
      );
      const magic = Buffer.from(abiBytes.subarray(0, 4)).toString('ascii');
      expect(magic).to.equal('ZGAR');
      const version = abiSection.data.getUint16(4, true);
      expect(version).to.equal(1);
      const descriptorTag = Buffer.from(abiBytes.subarray(12, 32)).toString('utf8');
      expect(descriptorTag).to.equal('wit-zigar:service:v1');

      const exportSection = sections.find((s) => s.type === SectionType.Export);
      expect(exportSection).to.be.an('object');
      const spExport = exportSection.exports.find(
        (e) => e.name === '__stack_pointer' && e.type === ObjectType.Global
      );
      expect(spExport, `__stack_pointer global export in ${optimize}`).to.deep.equal({
        name: '__stack_pointer',
        type: ObjectType.Global,
        index: 0,
      });

      const wasmBytes = new Uint8Array(
        processedDV.buffer,
        processedDV.byteOffset,
        processedDV.byteLength
      );
      expect(WebAssembly.validate(wasmBytes)).to.be.true;
      expect(Buffer.from(wasmBytes).indexOf(expectedAbiPayload)).to.be.at.least(0);
    }

    // Verify zigar_abi metadata and linksection("zigar:abi") magic via zigar JS bridge
    expect(serviceMod.zigar_abi).to.be.a('function');
    expect(serviceMod.zigar_abi.version).to.equal(1);
    expect(serviceMod.zigar_abi.zero_copy_extern).to.be.true;
    expect(serviceMod.zigar_abi.jspi_async).to.be.true;
    expect(await serviceMod.getZigarAbiMagic()).to.equal(0x5241475a);

    const debugLoaded = await transpileAndImportService({
      optimize: 'Debug',
      stripWASM: false,
      useJSPI: true,
      continuationStackSize: 8192,
      tag: 'e2e-debug',
    });
    try {
      const rect = await debugLoaded.mod.transformRect(
        { origin: { x: 1, y: 2 }, size: { x: 3, y: 4 } },
        5,
        6,
        2,
      );
      expect(rect.origin.x).to.equal(6);
      expect(rect.origin.y).to.equal(8);
      expect(rect.size.x).to.equal(6);
      expect(rect.size.y).to.equal(8);
    } finally {
      await debugLoaded.mod.__zigar?.abandon();
    }
  });

  it('should marshal zero-copy DataView-backed extern structs (Point, Rect) and slices ([]const Rect, []Point)', async function() {
    const {
      Point,
      Rect,
      PointSlice,
      RectSlice,
      Flags32,
      transformRect,
      sumRectAreas,
      scalePointsInPlace,
    } = serviceMod;

    // Verify zero-copy DataView backing on extern struct Rect (16 bytes: 4 x f32)
    const rawRectBuf = new ArrayBuffer(16);
    const rawRectDV = new DataView(rawRectBuf);
    rawRectDV.setFloat32(0, 10.5, true);
    rawRectDV.setFloat32(4, 20.25, true);
    rawRectDV.setFloat32(8, 8.0, true);
    rawRectDV.setFloat32(12, 4.0, true);

    const zeroCopyRect = Rect(rawRectDV);
    expect(zeroCopyRect.dataView.buffer).to.equal(rawRectBuf);
    expect(zeroCopyRect.origin.x).to.equal(10.5);
    expect(zeroCopyRect.origin.y).to.equal(20.25);
    expect(zeroCopyRect.size.x).to.equal(8.0);
    expect(zeroCopyRect.size.y).to.equal(4.0);

    const transformed = await transformRect(zeroCopyRect, -2.5, 4.75, 1.5);
    expect(transformed.origin.x).to.equal(8.0);
    expect(transformed.origin.y).to.equal(25.0);
    expect(transformed.size.x).to.equal(12.0);
    expect(transformed.size.y).to.equal(6.0);

    // Verify []const Rect zero-copy slice area summation
    const rects = new RectSlice([
      { origin: { x: 0, y: 0 }, size: { x: 3, y: 4 } },   // area = 12
      { origin: { x: 1, y: 1 }, size: { x: 5, y: 6 } },   // area = 30
      { origin: { x: -2, y: 3 }, size: { x: 2.5, y: 4 } }, // area = 10
    ]);
    const totalArea = await sumRectAreas(rects);
    expect(totalArea).to.equal(52.0);

    // Verify []Point zero-copy slice in-place mutation backed directly by a caller DataView
    const pointsBuf = new ArrayBuffer(3 * 8);
    const pointsDV = new DataView(pointsBuf);
    const initialCoords = [
      [ 2.0, -3.0 ],
      [ 4.5, 1.5 ],
      [ -1.0, 8.0 ],
    ];
    initialCoords.forEach(([ x, y ], i) => {
      pointsDV.setFloat32(i * 8, x, true);
      pointsDV.setFloat32(i * 8 + 4, y, true);
    });
    const pointSlice = PointSlice(pointsDV);
    expect(pointSlice.dataView.buffer).to.equal(pointsBuf);

    await scalePointsInPlace(pointSlice, 2.0);

    expect(pointSlice[0].x).to.equal(4.0);
    expect(pointSlice[0].y).to.equal(-6.0);
    expect(pointSlice[1].x).to.equal(9.0);
    expect(pointSlice[1].y).to.equal(3.0);
    expect(pointSlice[2].x).to.equal(-2.0);
    expect(pointSlice[2].y).to.equal(16.0);
    // Underlying ArrayBuffer was updated in-place
    expect(pointsDV.getFloat32(0, true)).to.equal(4.0);
    expect(pointsDV.getFloat32(4, true)).to.equal(-6.0);

    // Verify Flags32 extern struct
    const flags = new Flags32({ bits: 0b1010 });
    expect(flags.bits).to.equal(10);
  });

  it('should execute fastAbiRoundTrip via wit-zigar FastLower -> FastExportThunk -> FastLift', async function() {
    const { fastAbiRoundTrip } = serviceMod;
    const input = {
      origin: { x: 12.0, y: -4.0 },
      size: { x: 10.0, y: 20.0 },
    };
    const lifted = await fastAbiRoundTrip(input, 3.0, 9.0, 2.5);
    expect(lifted.origin.x).to.equal(15.0);
    expect(lifted.origin.y).to.equal(5.0);
    expect(lifted.size.x).to.equal(25.0);
    expect(lifted.size.y).to.equal(50.0);
  });

  it('should execute canonAbiAsyncSubtask with WASI 0.3 ShadowStack, TaskContext, and WaitableSet', async function() {
    const { canonAbiAsyncSubtask } = serviceMod;
    const sum1 = await canonAbiAsyncSubtask(123456, 654321);
    expect(sum1).to.equal(777777);

    const sum2 = await canonAbiAsyncSubtask(0x1000_0000, 0x2345_6789);
    expect(sum2).to.equal(0x3345_6789);
  });

  skip.if(typeof WebAssembly.Suspending !== 'function' || typeof WebAssembly.promising !== 'function').
  it('should execute 4 concurrent JSPI asyncComputeWithHost calls via Promise.all on isolated 16-byte-aligned continuation shadow stacks', async function() {
    const {
      asyncComputeWithHost,
      resetConcurrencyStats,
      getPeakConcurrent,
    } = serviceMod;

    await resetConcurrencyStats();

    const hostCallLog = [];
    const hostCallback = async (taskSeq, delayMs) => {
      hostCallLog.push({ event: 'suspend', taskSeq, delayMs });
      await delay(delayMs);
      hostCallLog.push({ event: 'resume', taskSeq, delayMs });
      // Encode scale step in upper byte ((taskSeq & 0xff) << 16) and delta in lower 16 bits
      return ((taskSeq & 0xff) << 16) | (taskSeq * 10);
    };

    const inputs = [
      { rect: { origin: { x: 1, y: 2 }, size: { x: 10, y: 20 } }, delayMs: 45 },
      { rect: { origin: { x: 3, y: 4 }, size: { x: 15, y: 25 } }, delayMs: 15 },
      { rect: { origin: { x: 5, y: 6 }, size: { x: 20, y: 30 } }, delayMs: 30 },
      { rect: { origin: { x: 7, y: 8 }, size: { x: 25, y: 35 } }, delayMs: 5 },
    ];

    const promises = inputs.map(({ rect, delayMs }) =>
      asyncComputeWithHost(rect, delayMs, hostCallback)
    );
    for (const p of promises) {
      expect(p).to.be.an.instanceOf(Promise);
    }

    const reports = await Promise.all(promises);
    expect(reports).to.have.lengthOf(4);

    // All 4 tasks must have suspended before the first timer resolved
    const firstFourEvents = hostCallLog.slice(0, 4).map((e) => e.event);
    expect(firstFourEvents).to.deep.equal([ 'suspend', 'suspend', 'suspend', 'suspend' ]);

    const peakFromModule = await getPeakConcurrent();
    expect(peakFromModule).to.be.at.least(4);

    const spAddresses = [];
    reports.forEach((report, idx) => {
      const taskSeq = idx + 1;
      const expectedDelta = taskSeq * 10;
      const expectedScale = 1.0 + taskSeq / 10.0;
      const { rect: inputRect } = inputs[idx];

      expect(report.suspension_count).to.equal(taskSeq);
      expect(report.host_value).to.equal(((taskSeq & 0xff) << 16) | expectedDelta);
      expect(report.rect.origin.x).to.be.closeTo(inputRect.origin.x + expectedDelta, 1e-4);
      expect(report.rect.origin.y).to.be.closeTo(inputRect.origin.y + expectedDelta * 0.5, 1e-4);
      expect(report.rect.size.x).to.be.closeTo(inputRect.size.x * expectedScale, 1e-4);
      expect(report.rect.size.y).to.be.closeTo(inputRect.size.y * expectedScale, 1e-4);

      // Verify peak concurrency >= 4 across the JSPI suspension point
      expect(report.peak_concurrent).to.be.at.least(4);

      // Verify 16-byte alignment and preservation of __stack_pointer across suspension & resumption
      expect(report.sp_before).to.be.above(0);
      expect(report.sp_before % 16).to.equal(0);
      expect(report.sp_after).to.equal(report.sp_before);
      spAddresses.push(report.sp_before);
    });

    // Verify all 4 concurrent continuations ran on distinct, non-overlapping shadow stacks
    const uniqueSp = new Set(spAddresses);
    expect(uniqueSp.size).to.equal(4);
    const sortedSp = [ ...spAddresses ].sort((a, b) => a - b);
    for (let i = 1; i < sortedSp.length; i++) {
      expect(sortedSp[i] - sortedSp[i - 1]).to.be.at.least(8192);
    }
  });

  it('should execute zigar wit subcommand via runWit and CLI entry points (Issue #29)', async function() {
    const witCliBuildDir = join(BUILD_DIR, 'wit-cli');
    const witOpts = {
      silent: true,
      zigPath: WAZIG_BIN,
      buildDir: witCliBuildDir,
    };

    // 1. Verify `zigar wit --help`
    const helpRes = await runWit([ '--help' ], witOpts);
    expect(helpRes.code).to.equal(0);
    expect(helpRes.stdout).to.include('Usage:\n  zigar wit <file.wit | dir>');
    expect(helpRes.stdout).to.include('zigar wit --wasi');
    expect(helpRes.stdout).to.include('zigar wit --detect-zigar-abi');

    // 2. Generate Zig bindings from sample.wit to an output file
    const sampleWitPath = resolve(__dirname, '../../wit-zigar/test/fixtures/sample.wit');
    const outZigPath = join(TMP_ROOT, 'generated-sample.zig');
    const genFileRes = await runWit([ sampleWitPath, '-o', outZigPath ], witOpts);
    expect(genFileRes.code).to.equal(0);
    const generatedZig = await readFile(outZigPath, 'utf8');
    expect(generatedZig).to.include('pub const world_name = "zigar:sample/sample-world@0.1.0";');
    expect(generatedZig).to.include('pub const Rect = extern struct');
    expect(generatedZig).to.include('pub const transform_rect_Fn');

    // 3. Generate Memory64 WASI 0.3 bindings via `--wasi` and `--wasm64`
    const wasiRes = await runWit([ '--wasi', 'wasi:cli/imports@0.3.0', '--wasm64' ], witOpts);
    expect(wasiRes.code).to.equal(0);
    expect(wasiRes.stdout).to.include('pub const world_name = "wasi:cli/imports@0.3.0";');
    expect(wasiRes.stdout).to.include('pub const is_wasm64 = true;');
    expect(wasiRes.stdout).to.include('pub const get_arguments_Fn');

    // 4. Inspect Wasm binaries with and without a "zigar:abi" custom section
    const minimalWasm = new Uint8Array([ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 ]);
    const wasmWithoutAbiPath = join(TMP_ROOT, 'plain.wasm');
    await writeFile(wasmWithoutAbiPath, minimalWasm);

    const ifaceStr = Buffer.from('zigar:sample/guest-service@0.1.0', 'utf8');
    const funcStr = Buffer.from('transform-rect', 'utf8');
    const exportStr = Buffer.from('__zigar_fast_zigar:sample/guest-service@0.1.0#transform_rect', 'utf8');
    const abiPayloadLen = 20 + 4 + ifaceStr.length + 4 + funcStr.length + 4 + exportStr.length + 20;
    const abiPayloadBuf = new ArrayBuffer(abiPayloadLen);
    const abiPayloadDV = new DataView(abiPayloadBuf);
    const abiPayloadBytes = new Uint8Array(abiPayloadBuf);
    let pos = 0;
    abiPayloadBytes.set(Buffer.from('ZGAR', 'ascii'), pos); pos += 4;
    abiPayloadDV.setUint16(pos, 1, true); pos += 2; // version = 1
    abiPayloadDV.setUint16(pos, 4, true); pos += 2; // flags: zero_copy_slices = true
    abiPayloadDV.setBigUint64(pos, 0x99n, true); pos += 8; // world_hash
    abiPayloadDV.setUint32(pos, 1, true); pos += 4; // entry_count = 1
    for (const s of [ ifaceStr, funcStr, exportStr ]) {
      abiPayloadDV.setUint32(pos, s.length, true); pos += 4;
      abiPayloadBytes.set(s, pos); pos += s.length;
    }
    abiPayloadDV.setBigUint64(pos, 0xcafe1234n, true); pos += 8; // abi_hash
    abiPayloadDV.setUint32(pos, 52, true); pos += 4; // arg_struct_size
    abiPayloadDV.setUint32(pos, 4, true); pos += 4; // arg_struct_align
    abiPayloadDV.setUint32(pos, 2, true); pos += 4; // flags: FLAG_IS_BLITTABLE_ONLY

    const parsedMinimal = parseBinary(new DataView(minimalWasm.buffer));
    parsedMinimal.sections.push({
      type: SectionType.Custom,
      name: 'zigar:abi',
      data: abiPayloadDV,
    });
    const repackedDV = repackBinary({
      sections: parsedMinimal.sections,
      size: parsedMinimal.size + abiPayloadLen + 32,
    });
    const wasmWithAbiPath = join(TMP_ROOT, 'with-zigar-abi.wasm');
    await writeFile(
      wasmWithAbiPath,
      new Uint8Array(repackedDV.buffer, repackedDV.byteOffset, repackedDV.byteLength)
    );

    const detectPresentRes = await runWit([ '--detect-zigar-abi', wasmWithAbiPath ], witOpts);
    expect(detectPresentRes.code).to.equal(0);
    expect(detectPresentRes.stdout).to.include('zigar:abi v1');
    expect(detectPresentRes.stdout).to.include(
      'zigar:sample/guest-service@0.1.0#transform-rect -> __zigar_fast_zigar:sample/guest-service@0.1.0#transform_rect'
    );

    const detectAbsentRes = await runWit([ '--detect-zigar-abi', wasmWithoutAbiPath ], witOpts);
    expect(detectAbsentRes.code).to.equal(0);
    expect(detectAbsentRes.stdout).to.include('No "zigar:abi" section present.');

    // 5. Directory input with deps/ and relative `-o` path using `cwd` option
    const witDirRoot = join(TMP_ROOT, 'wit-dir-input');
    mkdirSync(join(witDirRoot, 'deps', 'dep-pkg'), { recursive: true });
    await writeFile(
      join(witDirRoot, 'deps', 'dep-pkg', 'dep.wit'),
      'package acme:dep-pkg@0.1.0;\ninterface shared {\n  record token { id: u64 }\n}\n',
      'utf8'
    );
    await writeFile(
      join(witDirRoot, 'main.wit'),
      'package acme:app@0.1.0;\ninterface api {\n  use acme:dep-pkg/shared@0.1.0.{token};\n  verify: func(t: token) -> bool;\n}\nworld app-world {\n  import acme:dep-pkg/shared@0.1.0;\n  import api;\n}\n',
      'utf8'
    );
    const dirRes = await runWit([ '.', '-o', 'rel-dir-out.zig' ], {
      ...witOpts,
      cwd: witDirRoot,
    });
    expect(dirRes.code).to.equal(0);
    const relDirGenerated = await readFile(join(witDirRoot, 'rel-dir-out.zig'), 'utf8');
    expect(relDirGenerated).to.include('pub const Token = extern struct');
    expect(relDirGenerated).to.include('pub const verify_Fn');

    // 6. Verify non-zero exit code on invalid / missing CLI arguments
    const errRes = await runWit([ '--unknown-flag' ], witOpts);
    expect(errRes.code).to.not.equal(0);
    expect(errRes.stderr).to.include('UnknownOption');

    // 7. End-to-end CLI binary execution for `zigar wit --help` and `node-zigar help`
    cpSync(witCliBuildDir, join(TMP_ROOT, 'zigar-build'), { recursive: true });
    const cliEnv = {
      ...process.env,
      TMPDIR: TMP_ROOT,
      ZIG_PATH: WAZIG_BIN,
    };
    const zigarCliPath = resolve(__dirname, '../bin/cli.js');
    const { stdout: zigarWitHelpStdout } = await execFileAsync(
      process.execPath,
      [ zigarCliPath, 'wit', '--help' ],
      { env: cliEnv }
    );
    expect(zigarWitHelpStdout).to.include('Usage:\n  zigar wit <file.wit | dir>');
    expect(zigarWitHelpStdout).to.include('zigar wit --wasi');
    expect(zigarWitHelpStdout).to.include('zigar wit --detect-zigar-abi');

    const nodeZigarCliPath = resolve(__dirname, '../../node-zigar/bin/cli.js');
    const { stdout: nodeZigarHelpStdout } = await execFileAsync(
      process.execPath,
      [ nodeZigarCliPath, 'help' ],
      { env: cliEnv }
    );
    expect(nodeZigarHelpStdout).to.include('wit [args]');
    expect(nodeZigarHelpStdout).to.include('Generate Zig bindings from WIT or inspect zigar:abi sections');
  });
});
