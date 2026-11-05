import { execFile, spawn } from 'node:child_process';
import { accessSync, constants as fsConstants, writeFileSync } from 'node:fs';
import fs, { readdir, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import { basename, delimiter, dirname, isAbsolute, join, parse, resolve, sep } from 'node:path';
import { fileURLToPath, URL } from 'node:url';
import { promisify } from 'node:util';
import {
  acquireLock, copyFile, copyZonFile, createDirectory, deleteDirectory, deleteFile, getArch,
  getDirectoryStats, getLibraryExt, getPlatform, releaseLock, sha1
} from './utility-functions.js';

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
        if (config.useBuildExe) {
          const builtWasmPath = join(moduleBuildDir, config.relOutputPath);
          if (builtWasmPath !== outputPath) {
            await createDirectory(dirname(outputPath));
            await copyFile(outputPath, builtWasmPath);
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
    const useLocalCacheEnv = args[0] === 'build-exe' || args[0] === 'translate-c';
    const env = {
      ...process.env,
      ZIG_LOCAL_CACHE_DIR: '.zig-cache',
      ...(useLocalCacheEnv ? {
        ZIG_GLOBAL_CACHE_DIR: '.zig-cache',
      } : {}),
    };
    if (isWazig) {
      delete env.ZIG_LIB_DIR;
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
    await createDirectory(join(dir, config.optimize));
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

export function getModuleCachePath(srcPath, options) {
  const {
    optimize,
  } = options;
  const src = parse(srcPath);
  const folder = basename(src.dir).slice(0, 16).trim() + '-' + sha1(src.dir).slice(0, 8);
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
  const {
    platform = getPlatform(),
    arch = getArch(),
    optimize = 'Debug',
    isWASM = false,
    useLibc = isWASM ? false : true,
    useLLVM = null,
    useRedirection = true,
    usePthreadEmulation = false,
    clean = false,
    buildDir = join(os.tmpdir(), 'zigar-build'),
    buildDirSize = 4294967296,
    zigPath: zigPathOption,
    zigArgs: zigArgsStr = '',
    useWazig: useWazigOption,
    multithreaded = (isWASM) ? false : true,
    persistent = false,
    stackSize = 256 * 1024,
    maxMemory = (isWASM && multithreaded) ? 64 * 1024 * 1024 : undefined,
    evalBranchQuota = 2000000,
    omitFunctions = false,
    omitVariables = false,
    ignoreBuildFile = false,
    useBuildExe: useBuildExeOption,
  } = options;
  const src = parse(srcPath ?? '');
  const mod = parse(modPath ?? '');
  const moduleName = mod.name || src.name;
  const modulePath = (src.name !== '?') ? srcPath : undefined;
  const moduleDir = src.dir + sep;
  const modulePrefix = basename(moduleName).slice(0, 16);
  const moduleHash = sha1(moduleDir).slice(0, 8);
  const moduleBuildDir = join(buildDir, modulePrefix + '-' + moduleHash);
  const outputPath = (() => {
    if (!modPath && isWASM) {
      // save output in build folder
      return join(moduleBuildDir, optimize, `${src.name}.wasm`);
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
  const useBuildExe = Boolean(
    modulePath && (useBuildExeOption ?? (isWASM && !hasCustomBuildFile && !extraFilePath && !packageConfigPath && !zigArgsStr.trim() && useLLVM !== true))
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
    useWazig = !['0', 'false', 'no'].includes(process.env.USE_WAZIG.toLowerCase());
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
  const relOutputPath = join(optimize, `${src.name}.wasm`);
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
    isWASM,
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