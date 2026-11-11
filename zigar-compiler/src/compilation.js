import { execFile, spawn } from 'node:child_process';
import { accessSync, constants as fsConstants, writeFileSync } from 'node:fs';
import fs, { readdir, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import { basename, delimiter, dirname, isAbsolute, join, parse, relative, resolve, sep } from 'node:path';
import { fileURLToPath, URL } from 'node:url';
import { promisify } from 'node:util';
import {
  acquireLock, copyFile, copyZonFile, createDirectory, deleteDirectory, deleteFile, getArch,
  getDirectoryStats, getLibraryExt, getPlatform, releaseLock, sha1
} from './utility-functions.js';
import { fixWasm64TlsGlobals } from './wasm-decoding.js';

const execFileAsync = promisify(execFile);

let cachedWazigPathEnv;
let cachedHasWazig;

export function hasWazigCommand() {
  const pathEnv = process.env.PATH ?? '';
  if (pathEnv === cachedWazigPathEnv && cachedHasWazig !== undefined) {
    return cachedHasWazig;
  }
  cachedWazigPathEnv = pathEnv;
  const binName = process.platform === 'win32' ? 'wazig.exe' : 'wazig';
  cachedHasWazig = pathEnv.split(delimiter).some(dir => {
    if (!dir) return false;
    try {
      accessSync(join(dir, binName), fsConstants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
  return cachedHasWazig;
}

export async function test(srcPath, options) {
  const { silent = false, extraArgs = [] } = options;
  const config = await createConfig(srcPath, '', { ...options, useRedirection: false, useBuildExe: false });
  const { zigPath, moduleBuildDir } = config;
  // create config file
  await createProject(config, moduleBuildDir);
  const cwd = moduleBuildDir;
  const stdio = (silent) ? 'pipe' : 'inherit';
  const child = spawn(zigPath, [ 'build', 'test', ...extraArgs ], { cwd, stdio, windowsHide: true });
  const output = [];
  child.stderr?.on('data', chunk => output.push(chunk));
  const code = await new Promise(resolve => child.on('close', resolve));
  const blob = new Blob(output);
  return { code, stderr: await blob.text() };
}

const witWasmModuleCache = new Map();

async function findWitZigarSrcDir() {
  const candidates = [
    fileURLToPath(new URL('../zig/wit-zigar/src', import.meta.url)),
    fileURLToPath(new URL('../../wit-zigar/src', import.meta.url)),
  ];
  for (const dir of candidates) {
    try {
      const info = await stat(join(dir, 'main.zig'));
      if (info.isFile()) {
        return dir;
      }
    } catch {}
  }
  throw new Error('Unable to locate wit-zigar source directory (main.zig)');
}

function resolveWitZigPath(zigPathOption, useWazigOption) {
  if (zigPathOption !== undefined) {
    return zigPathOption;
  } else if (useWazigOption !== undefined) {
    return useWazigOption ? (process.env.WA_ZIG_PATH || 'wazig') : (process.env.ZIG_PATH || 'zig');
  } else if (process.env.ZIG_PATH) {
    return process.env.ZIG_PATH;
  } else if (process.env.USE_WAZIG !== undefined && process.env.USE_WAZIG !== '') {
    const envUseWazig = !['0', 'false', 'no'].includes(process.env.USE_WAZIG.toLowerCase());
    return envUseWazig ? 'wazig' : 'zig';
  } else if (hasWazigCommand()) {
    return 'wazig';
  } else {
    return 'zig';
  }
}

export async function runWit(args = [], options = {}) {
  const {
    cwd: runCwd = process.cwd(),
    silent = false,
    buildDir = join(os.tmpdir(), 'zigar-build'),
    optimize = 'ReleaseSmall',
    recompile = false,
    zigPath: zigPathOption,
    useWazig: useWazigOption,
    onStart,
    onEnd,
  } = options;
  const witZigarSrcDir = await findWitZigarSrcDir();
  const zigPath = resolveWitZigPath(zigPathOption, useWazigOption);
  const witBuildDir = join(buildDir, 'wit-zigar-cli-' + sha1(`${witZigarSrcDir}:${zigPath}`).slice(0, 8));
  const wasmPath = join(witBuildDir, optimize, 'wit-zigar.wasm');
  const metaPath = join(witBuildDir, optimize, 'wit-zigar.meta.json');
  const pidPath = `${witBuildDir}.pid`;
  await acquireLock(pidPath);
  let wasmModule;
  try {
    const getWasmMTime = async () => {
      try {
        const stats = await stat(wasmPath);
        return stats.mtimeMs;
      } catch {}
    };
    const getSavedMeta = async () => {
      try {
        return JSON.parse(await readFile(metaPath, 'utf-8'));
      } catch {
        return null;
      }
    };
    const [ wasmMTimeBefore, srcStats, savedMeta ] = await Promise.all([
      getWasmMTime(),
      getDirectoryStats(witZigarSrcDir),
      getSavedMeta(),
    ]);
    const metaMatches = Boolean(
      savedMeta &&
      savedMeta.size === srcStats.size &&
      savedMeta.mtimeMs === srcStats.mtimeMs &&
      savedMeta.zigPath === zigPath
    );
    if (!wasmMTimeBefore || !metaMatches || wasmMTimeBefore < srcStats.mtimeMs || recompile === true) {
      await stageDirectory(witZigarSrcDir, join(witBuildDir, 'src'), (name, isDir) => {
        if (isDir) {
          return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name);
        }
        return name.endsWith('.zig') || name.endsWith('.wit') || name.endsWith('.wasm') || name === 'NOTICE';
      });
      await createDirectory(join(witBuildDir, optimize));
      const sharedCacheDir = join(buildDir, `.zig-cache-${sha1(zigPath).slice(0, 8)}`);
      const localCacheDir = join(witBuildDir, '.zig-cache');
      await syncCacheDir(sharedCacheDir, localCacheDir);
      const zigArgs = [
        'build-exe',
        'src/main.zig',
        '--cache-dir', '.zig-cache',
        '--global-cache-dir', '.zig-cache',
        '-target', 'wasm32-wasi',
        '-O' + optimize,
        '-fsingle-threaded',
        `-femit-bin=${join(optimize, 'wit-zigar.wasm')}`,
      ];
      await runCompiler(zigPath, zigArgs, { cwd: witBuildDir, onStart, onEnd });
      await syncCacheDir(localCacheDir, sharedCacheDir);
      await writeFile(metaPath, JSON.stringify({
        size: srcStats.size,
        mtimeMs: srcStats.mtimeMs,
        zigPath,
      }));
    }
    const wasmMTime = await getWasmMTime();
    const cached = witWasmModuleCache.get(wasmPath);
    if (cached && !recompile && cached.mtimeMs === wasmMTime && cached.srcMtimeMs === srcStats.mtimeMs && cached.srcSize === srcStats.size) {
      wasmModule = cached.module;
    } else {
      const wasmBytes = await readFile(wasmPath);
      wasmModule = await WebAssembly.compile(wasmBytes);
      witWasmModuleCache.set(wasmPath, {
        mtimeMs: wasmMTime,
        srcMtimeMs: srcStats.mtimeMs,
        srcSize: srcStats.size,
        module: wasmModule,
      });
    }
  } finally {
    await releaseLock(pidPath);
  }
  const hostRoot = parse(resolve(runCwd)).root || '/';
  const toWasiPath = (p) => {
    const resolved = resolve(runCwd, p);
    const rel = relative(hostRoot, resolved);
    if (isAbsolute(rel) || rel.startsWith('..')) {
      throw new Error(`Path lies outside WASI preopen root (${hostRoot}): ${p}`);
    }
    return rel.split(sep).join('/') || '.';
  };
  const normalizedArgs = [];
  for (let i = 0; i < args.length; i++) {
    const arg = String(args[i]);
    if (arg === '-o' || arg === '--detect-zigar-abi') {
      normalizedArgs.push(arg);
      if (i + 1 < args.length) {
        normalizedArgs.push(toWasiPath(String(args[++i])));
      }
    } else if (arg === '--world' || arg === '--wasi') {
      normalizedArgs.push(arg);
      if (i + 1 < args.length) {
        normalizedArgs.push(String(args[++i]));
      }
    } else if (!arg.startsWith('-')) {
      normalizedArgs.push(toWasiPath(arg));
    } else {
      normalizedArgs.push(arg);
    }
  }
  const origEmitWarning = process.emitWarning;
  let WASI;
  let wasi;
  process.emitWarning = function(warning, ...warningArgs) {
    const msg = typeof warning === 'string' ? warning : warning?.message;
    if (String(msg).includes('WASI')) return;
    return origEmitWarning.call(this, warning, ...warningArgs);
  };
  try {
    ({ WASI } = await import('node:wasi'));
    wasi = new WASI({
      version: 'preview1',
      args: [ 'zigar-wit', ...normalizedArgs ],
      env: process.env,
      preopens: { '/': hostRoot },
      returnOnExit: true,
    });
  } finally {
    process.emitWarning = origEmitWarning;
  }
  const rawImports = typeof wasi.getImportObject === 'function'
    ? wasi.getImportObject()
    : { wasi_snapshot_preview1: wasi.wasiImport };
  const wasiImport = { ...rawImports.wasi_snapshot_preview1 };
  const importObject = { ...rawImports, wasi_snapshot_preview1: wasiImport };
  const origPathOpen = wasiImport.path_open;
  if (typeof origPathOpen === 'function') {
    wasiImport.path_open = (fd, dirflags, pathPtr, pathLen, oflags, fsRightsBase, fsRightsInheriting, fdflags, openedFdPtr) => {
      return origPathOpen(fd, dirflags, pathPtr, pathLen, oflags, fsRightsBase, 0xfffffffn, fdflags, openedFdPtr);
    };
  }
  wasiImport.proc_exit = (rval) => {
    const exitErr = new Error(`WASI exit: ${rval}`);
    exitErr.isWasiExit = true;
    exitErr.code = rval >>> 0;
    throw exitErr;
  };
  const origFdWrite = wasiImport.fd_write;
  const stdoutChunks = [];
  const stderrChunks = [];
  let instance;
  wasiImport.fd_write = (fd, iovsPtr, iovsLen, nwrittenPtr) => {
    if (fd === 1 || fd === 2) {
      const { buffer } = instance.exports.memory;
      const view = new DataView(buffer);
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovsPtr + i * 8, true);
        const len = view.getUint32(iovsPtr + i * 8 + 4, true);
        if (len > 0) {
          const chunk = Buffer.from(buffer.slice(ptr, ptr + len));
          if (fd === 1) {
            stdoutChunks.push(chunk);
            if (!silent) {
              process.stdout.write(chunk);
            }
          } else {
            stderrChunks.push(chunk);
            if (!silent) {
              process.stderr.write(chunk);
            }
          }
          total += len;
        }
      }
      view.setUint32(nwrittenPtr, total, true);
      return 0;
    }
    return origFdWrite(fd, iovsPtr, iovsLen, nwrittenPtr);
  };
  instance = await WebAssembly.instantiate(wasmModule, importObject);
  let code = 0;
  try {
    const startResult = wasi.start(instance);
    if (typeof startResult === 'number') {
      code = startResult;
    }
  } catch (err) {
    if (err?.isWasiExit) {
      code = err.code;
    } else {
      throw err;
    }
  }
  const stdout = Buffer.concat(stdoutChunks).toString('utf-8');
  const stderr = Buffer.concat(stderrChunks).toString('utf-8');
  return { code, stdout, stderr };
}

export async function compile(srcPath, modPath, options) {
  const srcInfo = (srcPath) ? await stat(srcPath) : null;
  if (srcInfo?.isDirectory()) {
    srcPath = join(srcPath, '?');
  }
  const config = await createConfig(srcPath, modPath, options);
  const { outputPath } = config;
  let changed = false;
  let sourcePaths = [];
  if (srcPath) {
    const { zigPath, zigArgs, moduleBuildDir, pdbPath, optimize } = config;
    // only one process can compile a given file at a time
    const pidPath = `${moduleBuildDir}.pid`;
    await acquireLock(pidPath);
    const getOutputMTime = async () => {
      try {
        const stats = await stat(outputPath);
        return stats.mtimeMs;
      } catch (err) {
      }
    };
    const outputMTimeBefore = await getOutputMTime();
    try {
      if (!outputMTimeBefore || options.recompile !== false) {
        const { onStart, onEnd } = options;
        // create config file
        await createProject(config);
        const canShareCache = config.useBuildExe && !config.clean && config.buildDirSize > 0;
        const sharedCacheDir = canShareCache
          ? join(config.buildDir, `.zig-cache-${sha1(config.zigPath).slice(0, 8)}`)
          : null;
        const localCacheDir = join(moduleBuildDir, '.zig-cache');
        if (sharedCacheDir) {
          await syncCacheDir(sharedCacheDir, localCacheDir);
        }
        if (config.useBuildExe && config.translateCArgs) {
          const cCode = await runCompiler(zigPath, config.translateCArgs, { cwd: moduleBuildDir });
          await writeFile(join(moduleBuildDir, 'c.zig'), cCode);
        }
        // then run the compiler
        await runCompiler(zigPath, zigArgs, { cwd: moduleBuildDir, onStart, onEnd });
        if (sharedCacheDir) {
          await syncCacheDir(localCacheDir, sharedCacheDir);
        }
        const emittedWasmPath = config.useBuildExe
          ? join(moduleBuildDir, config.relOutputPath)
          : outputPath;
        if (config.arch === 'wasm64' && config.multithreaded) {
          const rawBytes = await readFile(emittedWasmPath);
          const rawDV = new DataView(rawBytes.buffer, rawBytes.byteOffset, rawBytes.byteLength);
          const fixedDV = fixWasm64TlsGlobals(rawDV);
          if (fixedDV !== rawDV) {
            await writeFile(emittedWasmPath, new Uint8Array(fixedDV.buffer, fixedDV.byteOffset, fixedDV.byteLength));
          }
        }
        if (config.useBuildExe) {
          if (emittedWasmPath !== outputPath) {
            await createDirectory(dirname(outputPath));
            await copyFile(outputPath, emittedWasmPath);
          }
        }
      }
    } catch(err) {
      if (err.code === 'ENOENT') {
        if (!outputMTimeBefore) {
          throw new MissingModule(outputPath);
        }
      } else {
        throw err;
      }
    } finally {
      // get list of files involved in build
      sourcePaths = await findSourcePaths(moduleBuildDir, config);
      if (config.clean) {
        await deleteDirectory(moduleBuildDir);
      }
      if (optimize != 'Debug' && pdbPath) {
        await deleteFile(pdbPath);
      }
      await releaseLock(pidPath);
      cleanBuildDirectory(config).catch(() => {});
    }
    const outputMTimeAfter = await getOutputMTime();
    changed = outputMTimeBefore !== outputMTimeAfter;  
    sourcePaths.push(config.buildFilePath);
    if (config.packageConfigPath) {
      sourcePaths.push(config.packageConfigPath);
    }
  }
  return { outputPath, changed, sourcePaths }
}

let lock = null;

async function getLock() {
  const previous = lock;  
  let unlock;
  lock = new Promise(resolve => unlock = resolve);
  await previous;
  return unlock;
}

export async function runCompiler(path, args, options) {
  const {
    cwd,
    onStart,
    onEnd,
  } = options;
  const unlock = await getLock();
  try {
    onStart?.();
    const isWazig = basename(path).startsWith('wazig');
    const useLocalCacheEnv = isWazig || args[0] === 'build-exe' || args[0] === 'translate-c';
    const env = {
      ...process.env,
      ZIG_LOCAL_CACHE_DIR: '.zig-cache',
      ...(useLocalCacheEnv ? {
        ZIG_GLOBAL_CACHE_DIR: '.zig-cache',
      } : {}),
    };
    if (isWazig) {
      delete env.ZIG_LIB_DIR;
      if (!env.GHR_TOOL_DIR && isAbsolute(path)) {
        env.GHR_TOOL_DIR = resolve(dirname(path), '..');
      }
    }
    const { stdout } = await execFileAsync(path, args, {
      cwd,
      env,
      windowsHide: true,
      maxBuffer: 16 * 1024 * 1024,
    });
    return stdout;
  } catch (err) {
    throw new CompilationError(path, args, cwd, err);
    /* c8 ignore next */
  } finally {
    unlock();
    onEnd?.();
  }
}

class CompilationError extends Error {
  constructor(path, args, cwd, err) {
    super([ `Zig compilation failed`, err.stderr ].filter(s => !!s).join('\n\n'));
    this.path = path;
    this.args = args;
    this.errno = err.errno;
    this.code = err.code;
    if (err.stderr) {
      try {
        const logPath = join(cwd, 'log');
        writeFileSync(logPath, err.stderr);
        this.log = logPath;
        /* c8 ignore next 2 */
      } catch (err) {
      }
    }
  }
}

class MissingModule extends Error {
  constructor(path) {
    super(`Module not found: ${path}`);
  }
}

export function formatProjectConfig(config) {
  const lines = [];
  const fields = [
    'moduleName', 'modulePath', 'moduleDir', 'outputPath', 'pdbPath', 'zigarSrcPath',
    'cHeaderPath', 'useLibc', 'useLLVM', 'useWazig', 'usePthreadEmulation', 'useRedirection', 'isWASM',
    'multithreaded', 'persistent', 'stackSize', 'maxMemory', 'evalBranchQuota', 'omitFunctions',
    'omitVariables',
  ];
  for (const [ name, value ] of Object.entries(config)) {
    if (fields.includes(name)) {
      const snakeCase = name.replace(/[A-Z]+/g, m => '_' + m.toLowerCase());
      lines.push(`pub const ${snakeCase} = ${JSON.stringify(value ?? null)};`);
    }
  }
  return lines.join('\n') + '\n';
}

export function formatOptionsZig(config) {
  return [
    `pub const eval_branch_quota: comptime_int = ${config.evalBranchQuota};`,
    `pub const omit_functions: bool = ${Boolean(config.omitFunctions)};`,
    `pub const omit_variables: bool = ${Boolean(config.omitVariables)};`,
    `pub const use_redirection: bool = ${Boolean(config.useRedirection)};`,
    `pub const use_pthread_emulation: bool = ${Boolean(config.usePthreadEmulation)};`,
    `pub const persistent: bool = ${Boolean(config.persistent)};`,
    `pub const module_path: [:0]const u8 = ${JSON.stringify(config.modulePath ?? '')};`,
    '',
  ].join('\n');
}

async function stageDirectory(srcDir, dstDir, filterFn) {
  await createDirectory(dstDir);
  const entries = await readdir(srcDir, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = join(srcDir, entry.name);
    const dstPath = join(dstDir, entry.name);
    if (!filterFn(entry.name, entry.isDirectory())) {
      continue;
    }
    if (entry.isDirectory()) {
      await stageDirectory(srcPath, dstPath, filterFn);
    } else if (entry.isFile()) {
      await copyFile(dstPath, srcPath);
    }
  }
}

async function syncCacheDir(srcDir, dstDir, isManifestDir = false) {
  let entries;
  try {
    entries = await readdir(srcDir, { withFileTypes: true });
  } catch {
    return;
  }
  await createDirectory(dstDir);
  for (const entry of entries) {
    if (entry.name === 'tmp') continue;
    const srcPath = join(srcDir, entry.name);
    const dstPath = join(dstDir, entry.name);
    if (entry.isDirectory()) {
      await syncCacheDir(srcPath, dstPath, entry.name === 'h');
    } else if (entry.isFile()) {
      try {
        await fs.link(srcPath, dstPath);
      } catch (err) {
        if (err.code === 'EEXIST') {
          if (isManifestDir) {
            try {
              const [srcStat, dstStat] = await Promise.all([stat(srcPath), stat(dstPath)]);
              if (srcStat.ino !== dstStat.ino && srcStat.mtimeMs > dstStat.mtimeMs) {
                await deleteFile(dstPath);
                await fs.link(srcPath, dstPath);
              }
            } catch {}
          }
        } else {
          try {
            await copyFile(dstPath, srcPath);
          } catch {}
        }
      }
    }
  }
}

export async function createProject(config, dir = config.moduleBuildDir) {
  await createDirectory(dir);
  const content = formatProjectConfig(config);
  const cfgFilePath = join(dir, 'build.cfg.zig');
  await writeFile(cfgFilePath, content);
  if (config.useBuildExe) {
    const optionsFilePath = join(dir, 'options.zig');
    await writeFile(optionsFilePath, formatOptionsZig(config));
    await stageDirectory(config.zigarSrcPath, join(dir, 'zig'), (name, isDir) => {
      if (isDir) {
        return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name);
      }
      if (name === 'build.zig' || name === 'build.extra.zig' || name === 'options.zig') {
        return false;
      }
      return name.endsWith('.zig') || name.endsWith('.h');
    });
    await stageDirectory(config.moduleDir, join(dir, 'src'), (name, isDir) => {
      if (isDir) {
        return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name) && !name.endsWith('.zigar');
      }
      return name.endsWith('.zig') || name.endsWith('.h') || name.endsWith('.c');
    });
    await createDirectory(join(dir, dirname(config.relOutputPath)));
  } else {
    const buildFilePath = join(dir, 'build.zig');
    await copyFile(buildFilePath, config.buildFilePath);
    const extraFilePath = join(dir, 'build.extra.zig');
    if (config.extraFilePath) {
      await copyFile(extraFilePath, config.extraFilePath);
    } else {
      await writeFile(extraFilePath, '');
    }
    if (config.packageConfigPath) {
      const packageConfigPath = join(dir, 'build.zig.zon');
      await copyZonFile(config.packageConfigPath, packageConfigPath);
    }
  }
}

const cwd = process.cwd();

export function getCachePath(options) {
  const {
    cacheDir = join(cwd, '.zigar-cache'),
  } = options;
  return cacheDir;
}

export function getModuleCachePath(srcPath, options = {}) {
  const {
    optimize,
    memory64 = false,
    arch,
  } = options;
  const isWasm64 = Boolean(memory64 || arch === 'wasm64');
  const src = parse(srcPath);
  const baseFolder = basename(src.dir).slice(0, 16).trim() + '-' + sha1(src.dir).slice(0, 8);
  const folder = isWasm64 ? `${baseFolder}-wasm64` : baseFolder;
  const cacheDir = getCachePath(options);
  return join(cacheDir, folder, optimize, `${src.name}.zigar`);
}

async function findModuleFile(moduleDir, fileName) {
  try {
    // add custom build file if one is found
    const path = moduleDir + fileName;
    await stat(path);
    return path;
  } catch (err) {
  }
}

export async function createConfig(srcPath, modPath, options = {}) {
  const memory64 = Boolean(options.memory64 || options.arch === 'wasm64');
  const isWASM = Boolean(memory64 || options.isWASM || options.arch === 'wasm32');
  const arch = memory64 ? 'wasm64' : (options.arch ?? (isWASM ? 'wasm32' : getArch()));
  const platform = memory64 ? 'wasi' : (options.platform ?? (isWASM ? 'wasi' : getPlatform()));
  const {
    optimize = 'Debug',
    useLibc = isWASM ? false : true,
    useLLVM = null,
    useRedirection = true,
    usePthreadEmulation = false,
    useResizableBuffer,
    clean = false,
    buildDir = join(os.tmpdir(), 'zigar-build'),
    buildDirSize = 4294967296,
    zigPath: zigPathOption,
    zigArgs: zigArgsStr = '',
    useWazig: useWazigOption,
    multithreaded = (isWASM) ? false : true,
    persistent = false,
    stackSize = 256 * 1024,
    maxMemory: rawMaxMemory,
    evalBranchQuota = 2000000,
    omitFunctions = false,
    omitVariables = false,
    ignoreBuildFile = false,
    useBuildExe: useBuildExeOption,
  } = options;
  let maxMemory;
  if (rawMaxMemory === 0 || rawMaxMemory === null || rawMaxMemory === Infinity) {
    maxMemory = undefined;
  } else if (rawMaxMemory !== undefined) {
    maxMemory = rawMaxMemory;
  } else if (isWASM) {
    if (multithreaded) {
      maxMemory = 64 * 1024 * 1024;
    } else if (useResizableBuffer !== false) {
      maxMemory = (arch === 'wasm64') ? 4294967296 : 1073741824;
    }
  }
  const src = parse(srcPath ?? '');
  const mod = parse(modPath ?? '');
  const moduleName = mod.name || src.name;
  const modulePath = (src.name !== '?') ? srcPath : undefined;
  const moduleDir = src.dir + sep;
  const modulePrefix = basename(moduleName).slice(0, 16);
  const moduleHash = sha1(moduleDir).slice(0, 8);
  const moduleBuildDir = join(buildDir, `${modulePrefix}-${moduleHash}${arch === 'wasm64' ? '-wasm64' : ''}`);
  const relOutputPath = join(optimize, arch === 'wasm64' ? `${src.name}.wasm64.wasm` : `${src.name}.wasm`);
  const outputPath = (() => {
    if (!modPath && isWASM) {
      // save output in build folder
      return join(moduleBuildDir, relOutputPath);
    } else {
      const ext = getLibraryExt(platform);
      return join(modPath, `${platform}.${arch}.${ext}`);
    }
  })();
  let pdbPath;
  if (platform === 'win32') {
    pdbPath = join(dirname(outputPath), `${platform}.${arch}.pdb`);
  }
  const zigarSrcPath = fileURLToPath(new URL('../zig/', import.meta.url));
  let buildFilePath = join(zigarSrcPath, `build.zig`);
  let hasCustomBuildFile = false;
  if (!ignoreBuildFile) {
    // use custom build file if one is found
    const customBuildFilePath = await findModuleFile(moduleDir, 'build.zig');
    if (customBuildFilePath) {
      const code = await readFile(customBuildFilePath, 'utf-8');
      const remaining = code.replace(/\/\/.*/g, '').trim();
      if (remaining) {
        buildFilePath = customBuildFilePath;
        hasCustomBuildFile = true;
      }
    }
  }
  // add path to build.extra.zig if it exists
  const extraFilePath = await findModuleFile(moduleDir, 'build.extra.zig');
  // add path to build.extra.h if it exists
  const cHeaderPath = await findModuleFile(moduleDir, 'build.extra.h');
  // add package manager manifest
  const packageConfigPath = await findModuleFile(moduleDir, 'build.zig.zon');
  const isWazigPath = Boolean(
    (zigPathOption && basename(zigPathOption).startsWith('wazig')) ||
    (!zigPathOption && process.env.ZIG_PATH && basename(process.env.ZIG_PATH).startsWith('wazig'))
  );
  const useBuildExe = Boolean(
    modulePath && (useBuildExeOption ?? (isWASM && !hasCustomBuildFile && !extraFilePath && !packageConfigPath && !zigArgsStr.trim() && (useLLVM !== true || isWazigPath)))
  );
  let useWazig;
  let zigPath;
  if (zigPathOption !== undefined) {
    zigPath = zigPathOption;
    useWazig = Boolean(useWazigOption ?? basename(zigPath).startsWith('wazig'));
  } else if (useWazigOption !== undefined) {
    useWazig = Boolean(useWazigOption);
    zigPath = useWazig ? (process.env.WA_ZIG_PATH || 'wazig') : (process.env.ZIG_PATH || 'zig');
  } else if (process.env.ZIG_PATH) {
    zigPath = process.env.ZIG_PATH;
    useWazig = basename(zigPath).startsWith('wazig');
  } else if (process.env.USE_WAZIG !== undefined && process.env.USE_WAZIG !== '') {
    const envUseWazig = !['0', 'false', 'no'].includes(process.env.USE_WAZIG.toLowerCase());
    useWazig = Boolean(envUseWazig && isWASM && useBuildExe && useLLVM !== true);
    zigPath = useWazig ? 'wazig' : 'zig';
  } else if (isWASM && useBuildExe && useLLVM !== true && hasWazigCommand()) {
    useWazig = true;
    zigPath = 'wazig';
  } else {
    useWazig = false;
    zigPath = 'zig';
  }
  // translate from names used by Node to those used by Zig
  const cpuArchs = {
    arm: 'arm',
    arm64: 'aarch64',
    ia32: 'x86',
    loong64: 'loong64',
    mips: 'mips',
    mipsel: 'mipsel',
    ppc: 'powerpc',
    ppc64: 'powerpc64le',
    s390: undefined,
    riscv64: 'riscv64',
    s390x: 's390x',
    x64: 'x86_64',
  };
  const osTags = {
    aix: 'aix',
    darwin: 'macos',
    freebsd: 'freebsd',
    linux: 'linux-gnu',
    openbsd: 'openbsd',
    sunos: 'solaris',
    win32: 'windows',
  };
  const cpuArch = cpuArchs[arch] ?? arch;
  const osTag = osTags[platform] ?? platform;
  const target = `${cpuArch}-${osTag}`;
  const cpu = multithreaded ? 'generic+atomics+bulk_memory' : 'generic';
  let zigArgs;
  let translateCArgs = null;
  if (useBuildExe) {
    zigArgs = [
      'build-exe',
      '--cache-dir', '.zig-cache',
      '--global-cache-dir', '.zig-cache',
      '-fno-entry',
      '--stack', `${stackSize}`,
      multithreaded ? '-fno-single-threaded' : '-fsingle-threaded',
      `-O${optimize}`,
      '-target', target,
      '-mcpu', cpu,
    ];
    if (useLLVM !== null) {
      zigArgs.push(useLLVM ? '-fllvm' : '-fno-llvm');
    }
    if (useLibc) {
      zigArgs.push('-lc');
    }
    zigArgs.push(
      '--name', moduleName,
      '-static',
      '-rdynamic',
      multithreaded ? '--import-memory' : '--import-table',
    );
    if (maxMemory !== undefined) {
      zigArgs.push(`--max-memory=${maxMemory}`);
    }
    zigArgs.push(
      '-mexec-model=reactor',
      '--dep', 'module',
      '--dep', 'options.zig',
      `-Mroot=${join('zig', 'stub.zig')}`,
      '-O' + optimize,
      '-target', target,
      '-mcpu', cpu,
      '-I', 'src',
      '--dep', 'zigar',
    );
    if (cHeaderPath) {
      zigArgs.push('--dep', 'c');
    }
    zigArgs.push(
      `-Mmodule=${join('src', basename(modulePath))}`,
      '-Moptions.zig=options.zig',
      '-O' + optimize,
      '-target', target,
      '-mcpu', cpu,
      `-Mzigar=${join('zig', 'zigar.zig')}`,
    );
    if (cHeaderPath) {
      zigArgs.push(
        '-O' + optimize,
        '-target', target,
        '-mcpu', cpu,
        ...(useLibc ? ['-lc'] : []),
        '-Mc=c.zig',
      );
    }
    zigArgs.push(`-femit-bin=${relOutputPath}`);
    if (cHeaderPath) {
      translateCArgs = [
        'translate-c',
        '--cache-dir', '.zig-cache',
        '--global-cache-dir', '.zig-cache',
        '-lc',
        '-target', target,
        `-O${optimize}`,
        '-I', 'src',
        join('src', basename(cHeaderPath)),
      ];
    }
  } else {
    zigArgs = zigArgsStr.split(/\s+/).filter(s => !!s);
    if (!zigArgs.find(s => /^[^-]/.test(s))) {
      zigArgs.unshift('build');
    }
    if (!zigArgs.find(s => /^\-Doptimize=/.test(s))) {
      zigArgs.push(`-Doptimize=${optimize}`);
    }
    if (!zigArgs.find(s => /^\-Dtarget=/.test(s))) {
      zigArgs.push(`-Dtarget=${target}`);
    }
    if (isWASM && !zigArgs.find(s => /^\-Dcpu=/.test(s))) {
      zigArgs.push(`-Dcpu=${cpu}`);
    }
  }
  return {
    platform,
    arch,
    optimize,
    moduleName,
    modulePath,
    moduleDir,
    moduleBuildDir,
    zigarSrcPath,
    buildDir,
    buildDirSize,
    buildFilePath,
    packageConfigPath,
    outputPath,
    relOutputPath,
    cHeaderPath,
    pdbPath,
    clean,
    zigPath,
    zigArgs,
    translateCArgs,
    useBuildExe,
    useWazig,
    useLibc,
    useLLVM,
    useRedirection,
    usePthreadEmulation,
    useResizableBuffer,
    isWASM,
    memory64,
    multithreaded,
    persistent,
    stackSize,
    maxMemory,
    evalBranchQuota,
    omitFunctions,
    omitVariables,
    ignoreBuildFile,
    extraFilePath,
  };
}

async function getManifestLists(buildPath) {
  let dirPath;
  let names;
  try {
    dirPath = join(buildPath, '.zig-cache', 'h');
    names = await readdir(dirPath);
    /* c8 ignore next 8 */
  } catch (err) {
    try {
      dirPath = join(buildPath, 'zig-cache', 'h');
      names = await readdir(dirPath);
    } catch (err) {
      names = [];
    }
  }
  return names.filter(n => /^\w{32}$/.test(n)).map(n => join(dirPath, n));
}

async function findSourcePaths(buildPath, config) {
  const realBuildPath = await realpath(buildPath);
  const manifestPaths = await getManifestLists(realBuildPath);
  const involved = {};
  for (const manifestPath of manifestPaths) {
    try {
      const data = await readFile(manifestPath);
      let offset = 41;
      while (offset < data.length) {
        const si = offset;
        while (data[offset] !== 0 && offset < data.length) offset++;
        const ei = offset;
        const pathBytes = data.subarray(si, ei);
        let srcPath = pathBytes.toString('utf-8');
        if (config?.useBuildExe) {
          let rel = srcPath;
          if (rel.startsWith(realBuildPath + sep)) {
            rel = rel.slice(realBuildPath.length + 1);
          } else if (rel.startsWith('./') || rel.startsWith('.\\')) {
            rel = rel.slice(2);
          }
          if (rel.startsWith('src/') || rel.startsWith('src\\')) {
            srcPath = config.moduleDir ? join(config.moduleDir, rel.slice(4)) : srcPath;
          } else if (rel.startsWith('zig/') || rel.startsWith('zig\\')) {
            srcPath = config.zigarSrcPath ? join(config.zigarSrcPath, rel.slice(4)) : srcPath;
          }
        }
        if(isAbsolute(srcPath) && !srcPath.startsWith(realBuildPath) && !srcPath.includes('/.cache/zig/')) {
          try {
            await stat(srcPath);
            involved[srcPath] = true;
            /* c8 ignore next */
          } catch {};
        }
        offset += 42;
      }
      /* c8 ignore next 2 */
    } catch (err) {
    }
  }
  if (config?.useBuildExe) {
    if (config.cHeaderPath) {
      try {
        await stat(config.cHeaderPath);
        involved[config.cHeaderPath] = true;
      } catch {}
    }
    const queue = [
      config.modulePath,
      config.zigarSrcPath ? join(config.zigarSrcPath, 'stub.zig') : null,
      config.zigarSrcPath ? join(config.zigarSrcPath, 'zigar.zig') : null,
    ].filter(Boolean);
    const visited = new Set();
    while (queue.length > 0) {
      const filePath = queue.shift();
      if (visited.has(filePath)) continue;
      visited.add(filePath);
      try {
        await stat(filePath);
        involved[filePath] = true;
        if (filePath.endsWith('.zig')) {
          const content = await readFile(filePath, 'utf-8');
          const dir = dirname(filePath);
          const regex = /@(?:import|embedFile)\(\s*"([^"]+)"\s*\)/g;
          let match;
          while ((match = regex.exec(content)) !== null) {
            const spec = match[1];
            if (spec === 'options.zig') continue;
            if (spec.endsWith('.zig') || spec.startsWith('.') || spec.includes('/')) {
              const resolved = resolve(dir, spec);
              if (!visited.has(resolved)) {
                queue.push(resolved);
              }
            }
          }
        }
      } catch {}
    }
  }
  return Object.keys(involved);
}

async function cleanBuildDirectory(config) {
  const { buildDir, buildDirSize } = config;
  try {
    const names = await readdir(buildDir);
    const list = [];
    let total = 0;
    for (const name of names) {
      const path = join(buildDir, name);
      const info = await stat(path);
      if (info.isDirectory()) {
        const { size, mtimeMs } = await getDirectoryStats(path);
        total += size;
        list.push({ path, size, mtimeMs });
      }
    }
    list.sort((a, b) => a.mtimeMs - b.mtimeMs);
    let free = Infinity;
    if (fs.statfs) {
      const { bsize, bavail } = await fs.statfs(buildDir);
      free = bsize * bavail;
    }
    for (const { path, size } of list) {
      if (!(total > buildDirSize) && (free > 1073741824)) {
        break;
      }
      try {
        const pidPath = `${path}.pid`;
        await acquireLock(pidPath, false);
        try {
          await deleteDirectory(path);
          total -= size;
          free += size;
        } finally {
          await releaseLock(pidPath);
        }
        /* c8 ignore next 2 */
      } catch (err) {
      }
    }
    /* c8 ignore next 2 */
  } catch (err) {
  }
}