'use strict';

var node_child_process = require('node:child_process');
var node_crypto = require('node:crypto');
var fs = require('node:fs/promises');
var node_module = require('node:module');
var os = require('node:os');
var node_path = require('node:path');
var node_url = require('node:url');
var node_util = require('node:util');
var node_fs = require('node:fs');
var node_wasi = require('node:wasi');
var child_process = require('child_process');
var fs$1 = require('fs');
var os$1 = require('os');
var tty = require('tty');

var _documentCurrentScript = typeof document !== 'undefined' ? document.currentScript : null;
const StructureType = {
  Primitive: 0};
const StructurePurpose = {
  Unknown: 0,
  JsValue: 12,
};
const MemberType = {
  Void: 0};
const MemberFlag = {
  IsReadOnly: 1 << 1};

const zigGobals = globalThis[Symbol.for('ZIGAR')] ??= {};

function __symbol(name) {
  return zigGobals[name] ??= Symbol(name);
}

function symbol(name) {
  return /*@__PURE__*/ __symbol(name);
}

const MEMORY = symbol('memory');
const SLOTS = symbol('slots');

(process.env.BITS == 64) ? 0n : 0;
(process.env.BITS == 64) ? 0xFFFF_FFFF_FFFF_FFFFn : 0xFFFF_FFFF;
(process.env.BITS == 64) ? -1n : -1;
(process.env.BITS == 64) ? 8 : 4;

BigInt(Number.MAX_SAFE_INTEGER);
BigInt(Number.MIN_SAFE_INTEGER);

function findObjects(structures, SLOTS) {
  const list = [];
  const found = new Map();
  const find = (object) => {
    if (!object || found.get(object)) {
      return;
    }
    found.set(object, true);
    list.push(object);
    if (object[SLOTS]) {
      for (const child of Object.values(object[SLOTS])) {
        find(child);
      }
    }
  };
  for (const structure of structures) {
    find(structure.instance.template);
    find(structure.static.template);
  }
  return list;
}

const require$1 = node_module.createRequire((typeof document === 'undefined' ? require('u' + 'rl').pathToFileURL(__filename).href : (_documentCurrentScript && _documentCurrentScript.tagName.toUpperCase() === 'SCRIPT' && _documentCurrentScript.src || new URL('index.cjs', document.baseURI).href)));
const execFileAsync$1 = node_util.promisify(node_child_process.execFile);

async function acquireLock(pidPath, wait = true, staleTime = 60000 * 5) {
  while (true)   {
    try {
      await createDirectory(node_path.dirname(pidPath));
      const handle = await fs.open(pidPath, 'wx');
      handle.write(`${process.pid}`);
      handle.close();
      break;
    } catch (err) {
      if (err.code === 'EEXIST') {
        if (await checkPidFile(pidPath, staleTime)) {
          if (!wait) {
            throw err;
          }
          await delay(250);
          continue;
        }
        /* c8 ignore next 3 */
      } else {
        throw err;
      }
    }
  }
}

async function releaseLock(pidPath) {
  await deleteFile(pidPath);
}

async function checkPidFile(pidPath, staleTime) {
  let stale = false;
  try {
    const pid = await loadFile(pidPath);
    if (pid) {
      /* c8 ignore start */
      const win32 = os.platform() === 'win32';
      const program = (win32) ? 'tasklist' : 'ps';
      const args = (win32) ? [ '/nh', '/fi', `pid eq ${pid}` ] : [ '-p', pid ];
      const { stdout } = await execFileAsync$1(program, args, { windowsHide: true });
      if (win32 && !stdout.includes(pid)) {
        throw new Error('Process not found');
      }
      /* c8 ignore end */
    }
    const stats = await fs.stat(pidPath);
    const diff = new Date() - stats.mtime;
    if (diff > staleTime) {
      stale = true;
    }
  } catch (err) {
    stale = true;
  }
  if (stale) {
    await deleteFile(pidPath);
  }
  return !stale;
}

async function copyFile(dstPath, srcPath) {
  const info = await fs.stat(srcPath);
  const data = await fs.readFile(srcPath);
  await fs.writeFile(dstPath, data);
  await fs.chmod(dstPath, info.mode);
}

async function loadFile(path, def) {
  try {
    return await fs.readFile(path, 'utf8');
  } catch (err) {
    return def;
  }
}

async function deleteFile(path) {
  try {
    await fs.unlink(path);
  } catch (err) {
    if (err.code !== 'ENOENT' && err.code !== 'ENOTDIR') {
      throw err;
    }
  }
}

async function createDirectory(path) {
  try {
    await fs.stat(path);
  } catch (err) {
    const dir = node_path.dirname(path);
    await createDirectory(dir);
    try {
      await fs.mkdir(path);
      /* c8 ignore next 5 */
    } catch (err) {
      if (err.code != 'EEXIST') {
        throw err;
      }
    }
  }
}

async function deleteDirectory(dir) {
  try {
    const list = await fs.readdir(dir);
    for (const name of list) {
      const path = node_path.join(dir, name);
      const info = await fs.lstat(path);
      if (info.isDirectory()) {
        await deleteDirectory(path);
      } else if (info) {
        await deleteFile(path);
      }
    }
    await fs.rmdir(dir);
  } catch (err) {
    if (err.code !== 'ENOENT') {
      throw err;
    }
  }
}

async function delay(ms) {
  await new Promise(r => setTimeout(r, ms));
}

function sha1(text) {
  const hash = node_crypto.createHash('sha1');
  hash.update(text);
  return hash.digest('hex');
}

// this function (along with getArch() and getLibraryExt()) need to be self-contained 
// such that we'd have functional code if we use toString() on it; it can only depend
// on the variable 'os' being available
function getPlatform() {
  let platform = os.platform();
  if (platform === 'linux') {
    // differentiate glibc from musl
    if (process.__gnu === undefined) {
      /* c8 ignore next 3 */
      if (process.versions?.electron || process.__nwjs) {
        process.__gnu = true;
      } else {
        const list = [];
        try {
          // scan ELF executable for imported shared libraries
          const { closeSync, openSync, readSync } = require$1('fs');
          const fd = openSync(process.execPath, 'r');
          const sig = new Uint8Array(8);
          readSync(fd, sig);
          for (const [ index, value ] of [ '\x7f', 'E', 'L', 'F' ].entries()) {
            if (sig[index] !== value.charCodeAt(0)) {
              throw new Error('Incorrect magic number');
            }
          }
          const bits = sig[4] * 32;
          const le = sig[5] === 1;
          const Ehdr = (bits === 64)
          ? { size: 64, e_shoff: 40, e_shnum: 60 }
          : { size: 52, e_shoff: 32, e_shnum: 48 };
          const Shdr = (bits === 64)
          ? { size: 64, sh_type: 4, sh_offset: 24, sh_size: 32, sh_link: 40 }
          : { size: 40, sh_type: 4, sh_offset: 16, sh_size: 20, sh_link: 24 };
          const Dyn = (bits === 64)
          ? { size: 16, d_tag: 0, d_val: 8 }
          : { size: 8, d_tag: 0, d_val: 4 };
          const Usize = (bits === 64) ? BigInt : Number;
          const read = (position, size) => {
            const buf = new DataView(new ArrayBuffer(Number(size)));
            // deno can't handle bigint position
            readSync(fd, buf, { position: Number(position) });
            buf.getUsize = (bits === 64) ? buf.getBigUint64 : buf.getUint32;
            return buf;
          };
          const SHT_DYNAMIC = 6;
          const DT_NEEDED = 1;
          const ehdr = read(0, Ehdr.size);
          let position = ehdr.getUsize(Ehdr.e_shoff, le);
          const sectionCount = ehdr.getUint16(Ehdr.e_shnum, le);
          const shdrs = [];
          for (let i = 0; i < sectionCount; i++, position += Usize(Shdr.size)) {
            shdrs.push(read(position, Shdr.size));
          }
          for (const shdr of shdrs) {
            const sectionType = shdr.getUint32(Shdr.sh_type, le);
            if (sectionType == SHT_DYNAMIC) {
              const link = shdr.getUint32(Shdr.sh_link, le);
              const strTableOffset = shdrs[link].getUsize(Shdr.sh_offset, le);
              const strTableSize = shdrs[link].getUsize(Shdr.sh_size, le);
              const strTable = read(strTableOffset, strTableSize);
              const dynamicOffset = shdr.getUsize(Shdr.sh_offset, le);
              const dynamicSize = shdr.getUsize(Shdr.sh_size, le);
              const entryCount = Number(dynamicSize / Usize(Dyn.size));
              position = dynamicOffset;
              for (let i = 0; i < entryCount; i++, position += Usize(Dyn.size)) {
                const entry = read(position, Dyn.size);
                const tag = entry.getUsize(Dyn.d_tag, le);
                if (tag === Usize(DT_NEEDED)) {
                  let offset = entry.getUsize(Dyn.d_val, le);
                  let name = '', c;
                  while (c = strTable.getUint8(Number(offset++))) {
                    name += String.fromCharCode(c);
                  }
                  list.push(name);
                }
              }
            }
          }
          closeSync(fd);
        } catch (err) {
        }
        process.__gnu = (list.length > 0) ? list.indexOf('libc.so.6') != -1 : true;
      }
    }
    /* c8 ignore next 3 */
    if (!process.__gnu) {
      platform += '-musl';
    }
  }
  return platform;
}

function getArch() {
  return os.arch();
}

function getLibraryExt(platform) {
  switch (platform) {
    case 'win32': return 'dll';
    case 'darwin': return 'dylib';
    default: return 'so';
  }
}

function normalizePath(url) {
  let archive;
  const parts = node_url.fileURLToPath(url).split(node_path.sep).map((part) => {
    if (part === 'app.asar') {
      archive = 'asar';
      return part + '.unpacked';
    }
    return part;
  });
  const path = parts.join(node_path.sep);
  return { path, archive }
}

async function getDirectoryStats(dirPath) {
  let size = 0, mtimeMs = 0;
  const names = await fs.readdir(dirPath);
  for (const name of names) {
    const path = node_path.join(dirPath, name);
    let info = await fs.stat(path);
    if(info.isDirectory()) {
      info = await getDirectoryStats(path);
    } else if (!info.isFile()) {
      continue;
    }
    size += info.size;
    if (mtimeMs < info.mtimeMs) {
      mtimeMs = info.mtimeMs;
    }
  }
  return { size, mtimeMs };
}

async function copyZonFile(srcPath, dstPath) {
  const srcDir = await fs.realpath(node_path.dirname(srcPath));
  const dstDir = await fs.realpath(node_path.dirname(dstPath));
  const srcCode = await fs.readFile(srcPath, 'utf-8');
  const dstCode = srcCode.replace(/(\.path\s+=\s+)"(.*?)"/g, (m0, pre, path) => {
    const srcModulePath = node_path.resolve(srcDir, path);
    const dstModulePath = node_path.relative(dstDir, srcModulePath);
    return pre + JSON.stringify(dstModulePath);
  });
  await fs.writeFile(dstPath, dstCode);
}

function generateCode(definition, params) {
  const { structures, jsModules = [] } = definition;
  const {
    declareFeatures = false,
    runtimeURL,
    binarySource = null,
    topLevelAwait = true,
    omitExports = false,
    mixinPaths = [],
    moduleOptions,
    envVariables = {},
    standaloneLoader,
    moduleFormat,
    dynamicJsImports = false,
    jsModuleResolver,
    moduleBaseURL,
  } = params;
  const exports = getExports(structures);
  const lines = [];
  const type = standaloneLoader?.type ?? moduleFormat ?? 'esm';
  const uniqueJsModules = [];
  const seenJsModules = new Set();
  for (const rawSpec of jsModules) {
    const spec = String(rawSpec);
    if (spec && !seenJsModules.has(spec)) {
      seenJsModules.add(spec);
      uniqueJsModules.push(spec);
    }
  }
  const staticJsImports = [];
  const dynamicJsModuleEntries = [];
  const preloadJsModules = [];
  for (const spec of uniqueJsModules) {
    let importSpec;
    if (typeof(jsModuleResolver) === 'function') {
      importSpec = jsModuleResolver(spec);
    } else if (spec.startsWith('virtual:') || spec.startsWith('\0')) {
      importSpec = null;
    } else {
      importSpec = spec;
    }
    if (dynamicJsImports) {
      if (typeof(importSpec) === 'string' && importSpec.length > 0) {
        dynamicJsModuleEntries.push({ specifier: spec, importSpecifier: importSpec });
        preloadJsModules.push(spec);
      }
      continue;
    }
    if (typeof(importSpec) === 'string' && importSpec.length > 0) {
      const ident = `__zigar_js_mod_${staticJsImports.length}`;
      staticJsImports.push({ specifier: spec, importSpecifier: importSpec, ident });
    }
  }
  const add = manageIndentation(lines);
  if (standaloneLoader) {
    const { addonDir } = standaloneLoader;
    if (type === 'esm') {
      add(`import { createRequire } from 'node:module';`);
      add(`import os from 'node:os';`);
      add(`import { dirname, resolve } from 'node:path';`);
      add(`import { fileURLToPath } from 'node:url';`);
      add(``);
      add(`const require = createRequire(import.meta.url);`);
      add(`const __dirname = dirname(fileURLToPath(import.meta.url));`);
    } else {
      add(`const os = require('os');`);
      add(`const { resolve } = require('path');`);
      add(``);
    }
    add(`const platform = getPlatform();`);
    add(`const arch = getArch();`);
    add(`const ext = getLibraryExt(platform);`);
    add(`const moduleName = \`\${platform}.\${arch}.\${ext}\`;`);
    add(`const addonName = \`\${platform}.\${arch}.node\`;`);
    add(`const { createEnvironment } = require(resolve(__dirname, ${escapeJsString(addonDir)}, addonName));`);
  } else if (type === 'cjs') {
    add(`const { createEnvironment } = require(${escapeJsString(runtimeURL)});`);
  } else {
    // loading through node-zigar/bun-zigar or WASM ESM
    add(`import { createEnvironment } from ${escapeJsString(runtimeURL)};`);
  }
  const effectiveMixinPaths = [ ...mixinPaths ];
  if (declareFeatures && !standaloneLoader && runtimeURL) {
    if (structures.some(s => s.purpose === StructurePurpose.JsValue) || definition.settings?.hasJsHostOps || uniqueJsModules.length > 0) {
      for (const reqPath of [ 'features/js-value-registry.js', 'structures/js-value.js' ]) {
        if (!effectiveMixinPaths.includes(reqPath)) {
          effectiveMixinPaths.push(reqPath);
        }
      }
    }
    if ((definition.settings?.hasJsHostOps || uniqueJsModules.length > 0) && !effectiveMixinPaths.includes('features/js-host-op.js')) {
      effectiveMixinPaths.push('features/js-host-op.js');
    }
  }
  for (const mixinPath of effectiveMixinPaths) {
    if (type === 'cjs') {
      add(`require(${escapeJsString(`${runtimeURL}/${mixinPath}`)});`);
    } else {
      add(`import '${runtimeURL}/${mixinPath}';`);
    }
  }
  for (const { importSpecifier, ident } of staticJsImports) {
    if (type === 'cjs') {
      add(`const ${ident} = require(${escapeJsString(importSpecifier)});`);
    } else {
      add(`import * as ${ident} from ${escapeJsString(importSpecifier)};`);
    }
  }
  // write out the structures as object literals
  addStructureDefinitions(lines, definition, moduleOptions);
  if (Object.keys(envVariables).length > 0) {
    add(`\n// set environment variables`);
    for (const [ name, value ] of Object.entries(envVariables)) {
      add(`process.env.${name} = ${escapeJsString(value)};`);
    }
  }
  add(`\n// create runtime environment`);
  add(`const env = createEnvironment();`);
  if (definition.settings?.hasJsHostOps || uniqueJsModules.length > 0) {
    if (typeof(moduleBaseURL) === 'string' && moduleBaseURL.length > 0) {
      add(`env.moduleBaseURL = ${escapeJsString(moduleBaseURL)};`);
    } else if (type === 'cjs') {
      add(`if (typeof __filename === 'string') env.moduleBaseURL = __filename;`);
    } else {
      add(`if (typeof import.meta?.url === 'string') env.moduleBaseURL = import.meta.url;`);
    }
  }
  if (staticJsImports.length > 0) {
    add(`env.registerJsModules({`);
    for (const { specifier, ident } of staticJsImports) {
      add(`${escapeJsString(specifier)}: ${ident},`);
    }
    add(`});`);
  }
  const inlineNativeDynamicAwait = Boolean(dynamicJsImports && dynamicJsModuleEntries.length > 0 && !moduleOptions && type === 'esm' && topLevelAwait);
  if (dynamicJsImports && dynamicJsModuleEntries.length > 0 && !inlineNativeDynamicAwait) {
    add(`env.registerJsModuleLoaders({`);
    for (const { specifier, importSpecifier } of dynamicJsModuleEntries) {
      add(`${escapeJsString(specifier)}: () => import(${escapeJsString(importSpecifier)}),`);
    }
    add(`});`);
  }
  add(`\n// recreate structures`);
  add(`env.recreateStructures(structures, settings);`);
  if (inlineNativeDynamicAwait) {
    for (const { specifier, importSpecifier } of dynamicJsModuleEntries) {
      add(`env.registerJsModule(${escapeJsString(specifier)}, await import(${escapeJsString(importSpecifier)}));`);
    }
  }
  if (binarySource) {
    if (moduleOptions) {
      add(`\n// initiate loading and compilation of WASM bytecodes`);
    } else {
      add(`\n// load shared library`);
    }
    add(`const source = ${binarySource};`);
    const loadOptions = (moduleOptions) ? {
      delay: !topLevelAwait,
      ...moduleOptions,
      ...(preloadJsModules.length > 0 ? { preloadJsModules } : {}),
    } : null;
    add(`env.loadModule(source, ${loadOptions ? escapeJsonLiteral(loadOptions) : null});`);
    // if top level await is used, we don't need to write changes into Zig memory buffers
    add(`env.linkVariables(${!topLevelAwait});`);
  } else if (standaloneLoader?.moduleDir) {
    const { moduleDir } = standaloneLoader;
    add(`env.loadModule(resolve(__dirname, ${JSON.stringify(moduleDir)}, moduleName));`);
    // write-back is never necessary in Node/Bun/Deno since loadModule() is synchronous
    add(`env.linkVariables(false);`);
  }
  add(`\n// export root namespace and its methods and constants`);
  let specialVarName;
  if (!omitExports) {
    // the first two exports are default and __zigar
    add(`const { constructor: v0 } = root;`);
    add(`const v1 = env.getSpecialExports();`);
    specialVarName = 'v1';
    if (exports.length > 2) {
      add(`const {`);
      for (const [ index, name ] of exports.entries()) {
        if (index >= 2) {
          add(`${name}: v${index},`);
        }
      }
      add(`} = v0;`);
    }
    if (type == 'esm') {
      add(`export {`);
      for (const [ index, name ] of exports.entries()) {
        add(`v${index} as ${name},`);
      }
      add(`};`);
    } else {
      add(`module.exports = {`);
      for (const [ index, name ] of exports.entries()) {
        add(`${name}: v${index},`);
      }
      add(`};`);
    }
  } else {
    add(`const { constructor } = root;`);
    add(`const __zigar = env.getSpecialExports();`);
    specialVarName = '__zigar';
  }
  if (moduleOptions && topLevelAwait && binarySource) {
    add(`await ${specialVarName}.init();`);
  }
  if (standaloneLoader) {
    add(`\n${getPlatform}`);
    add(`\n${getArch}`);
    add(`\n${getLibraryExt}`);
  }
  const code = lines.join('\n');
  return { code, exports, structures, jsModules: uniqueJsModules };
}

function escapeJsString(value) {
  return escapeJsonLiteral(String(value));
}

function escapeJsonLiteral(value) {
  return JSON.stringify(value)
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

function addStructureDefinitions(lines, definition, moduleOptions) {
  const { structures, settings } = definition;
  const add = manageIndentation(lines);
  const defaultStructure = {
    constructor: null,
    type: StructureType.Primitive,
    purpose: StructurePurpose.Unknown,
    flags: 0,
    signature: undefined,
    name: undefined,
    byteSize: undefined,
    align: 0,
    instance: {
      members: [],
      template: null,
    },
    static: {
      members: [],
      template: null,
    },
  };
  add(`\n// structure defaults`);
  add(`const s = {`);
  for (const [ name, value ] of Object.entries(defaultStructure)) {
    switch (name) {
      case 'instance':
      case 'static':
        add(`${name}: {`);
        for (const [ name2, value2 ] of Object.entries(value)) {
          add(`${name2}: ${JSON.stringify(value2)},`);
        }
        add(`},`);
        break;
      default:
        add(`${name}: ${JSON.stringify(value)},`);
    }
  }
  add(`};`);
  const defaultMember = {
    type: MemberType.Void,
    flags: 0,
  };
  add(`\n// member defaults`);
  add(`const m = {`);
  for (const [ name, value ] of Object.entries(defaultMember)) {
    add(`${name}: ${JSON.stringify(value)},`);
  }
  add(`};`);
  // create empty objects first, to allow objects to reference each other
  const structureNames = new Map();
  const structureMap = new Map();
  for (const [ index, structure ] of structures.entries()) {
    const varname = `s${index}`;
    structureNames.set(structure, varname);
    structureMap.set(structure.constructor, structure);
  }
  if (structureNames.size > 0) {
    add('\n// declare structure objects');
    for (const slice of chunk(structureNames.values(), 10)) {
      add(`const ${slice.map(n => `${n} = {}`).join(', ')};`);
    }
  }
  const objects = findObjects(structures, SLOTS);
  const objectNames = new Map();
  const views = [];
  for (const [ index, object ] of objects.entries()) {
    const varname = `o${index}`;
    objectNames.set(object, varname);
    if (object[MEMORY]) {
      views.push(object[MEMORY]);
    }
  }
  if (objectNames.size > 0) {
    add('\n// declare objects');
    for (const slice of chunk(objectNames.values(), 10)) {
      add(`const ${slice.map(n => `${n} = {}`).join(', ')};`);
    }
  }
  // define buffers
  const arrayBufferNames = new Map();
  let hasU;
  const addU = () => {
    if (!hasU) {
      add('\n// define byte arrays');
      add(`const U = i => new Uint8Array(i);`);
      hasU = true;
    }
  };
  let arrayCount = 0;
  const emptyBuffer = new ArrayBuffer(0);
  const zeroInit = function(ta) {
    for (const byte of ta) {
      if (byte !== 0) {
        return;
      }
    }
    return `${ta.length}`;
  };
  const existingInit = function(ta) {
    for (const [ buffer, name ] of arrayBufferNames) {
      if (buffer.byteLength === ta.byteLength) {
        const existing = new Uint8Array(buffer);
        let different = false;
        for (let i = 0; i < ta.length; i++) {
          if (existing[i] !== ta[i]) {
            different = true;
            break;
          }
        }
        if (!different) {
          return name;
        }
      }
    }
  };
  const listInit = function(ta) {
    return `[ ${ta.join(', ')} ]`;
  };
  for (const dv of views) {
    addU();
    const buffer = (dv.buffer.byteLength > 0) ? dv.buffer : emptyBuffer;
    if (!arrayBufferNames.get(buffer)) {
      const varname = `a${arrayCount++}`;
      const a = new Uint8Array(dv.buffer);
      add(`const ${varname} = U(${zeroInit(a) ?? existingInit(a) ?? listInit(a)});`);
      arrayBufferNames.set(buffer, varname);
    }
  }
  // add properties to objects
  let has$ = false;
  const add$ = () => {
    if (!has$) {
      add('\n// fill in object properties');
      add(`const $ = Object.assign;`);
      has$ = true;
    }
  };
  if (objects.length > 0) {
    for (const object of objects) {
      const varname = objectNames.get(object);
      const structure = structureMap.get(object.constructor);
      const { [MEMORY]: dv, [SLOTS]: slots } = object;
      add$();
      add(`$(${varname}, {`);
      if (structure) {
        add(`structure: ${structureNames.get(structure)},`);
      }
      if (dv) {
        const buffer = (dv.buffer.byteLength > 0) ? dv.buffer : emptyBuffer;
        const pairs = [ `array: ${arrayBufferNames.get(buffer)}` ];
        if (dv.byteLength < buffer.byteLength) {
          pairs.push(`offset: ${dv.byteOffset}`);
          pairs.push(`length: ${dv.byteLength}`);
        }
        add(`memory: { ${pairs.join(', ')} },`);
        const { handle } = dv;
        if (handle !== undefined) {
          add(`handle: ${typeof handle === 'bigint' ? `${handle}n` : handle},`);
        }
      }
      if (slots) {
        const pairs = [];
        for (const [ slot, child ] of Object.entries(slots)) {
          const varname = objectNames.get(child);
          if (varname) {
            pairs.push(`${slot}: ${varname}`);
          }
        }
        if (pairs.length > 0) {
          add(`slots: {`);
          for (const slice of chunk(pairs, 10)) {
            add(slice.join(', ') + ',');
          }
          add(`},`);
        }
      }
      add(`});`);
    }
  }
  if (structures.length > 0) {
    add('\n// fill in structure properties');
    for (const structure of structures) {
      const varname = structureNames.get(structure);
      add$();
      add(`$(${varname}, {`);
      add(`...s,`);
      for (const [ name, value ] of Object.entries(structure)) {
        if (isDifferent(value, defaultStructure[name])) {
          switch (name) {
            case 'constructor':
            case 'typedArray':
            case 'sentinel':
              break;
            case 'signature':
              add(`${name}: 0x${value.toString(16).padStart(16, '0')}n,`);
              break;
            case 'instance':
            case 'static': {
              const { members, template } = value;
              add(`${name}: {`);
              add(`members: [`);
              if (members) {
                for (const member of members) {
                  add(`{`);
                  add(`...m,`);
                  for (const [ name, value ] of Object.entries(member)) {
                    if (isDifferent(value, defaultMember[name])) {
                      switch (name) {
                        case 'structure':
                          add(`${name}: ${structureNames.get(value)},`);
                          break;
                        default:
                          add(`${name}: ${JSON.stringify(value)},`);
                      }
                    }
                  }
                  add(`},`);
                }
              }
              add(`],`);
              if (template) {
                add(`template: ${objectNames.get(template)}`);
              }
              add(`},`);
            } break;
            default:
              add(`${name}: ${JSON.stringify(value)},`);
          }
        }
      }
      add(`});`);
    }
  }
  add(`const structures = [`);
  for (const slice of chunk([ ...structureNames.values() ], 10)) {
    add(slice.join(', ') + ',');
  }
  add(`];`);
  const root = structures[structures.length - 1];
  add(`const root = ${structureNames.get(root)};`);
  const effectiveSettings = (moduleOptions?.memory64 && !settings.memory64)
    ? { ...settings, memory64: true }
    : settings;
  add(`const settings = {`);
  for (const [ name, value ] of Object.entries(effectiveSettings)) {
    if (name === 'memory64' && !value) continue;
    add(`${name}: ${value},`);
  }
  add(`};`);
  return lines;
}

function getExports(structures) {
  const root = structures[structures.length - 1];
  const { constructor } = root;
  const exportables = [];
  // export only members whose names are legal JS identifiers
  const legal = /^[$\w]+$/;
  for (const { name, flags } of root.static.members) {
    // only read-only properties are exportable
    if (flags & MemberFlag.IsReadOnly && legal.test(name)) {
      try {
        // make sure that getter wouldn't throw (possible with error union)
        constructor[name];
        exportables.push(name);
        /* c8 ignore next 2 */
      } catch (err) {
      }
    }
  }
  return [ 'default', '__zigar', ...exportables ];
}

function manageIndentation(lines) {
  let indent = 0;
  return (s) => {
    if (/^\s*[\]\}]/.test(s)) {
      indent--;
    }
    const lastLine = lines[lines.length - 1];
    if ((lastLine?.endsWith('[') && s.startsWith(']'))
     || (lastLine?.endsWith('{') && s.startsWith('}'))) {
      lines[lines.length - 1] += s;
    } else {
      lines.push(' '.repeat(indent * 2) + s);
    }
    if (/[\[\{]\s*$/.test(s)) {
      indent++;
    }
  };
}

function isDifferent(value, def) {
  if (value === def) {
    return false;
  }
  if (def == null) {
    return value != null;
  }
  if (typeof(def) === 'object' && typeof(value) === 'object') {
    const valueKeys = Object.keys(value);
    const defKeys = Object.keys(def);
    if (valueKeys.length !== defKeys.length) {
      return true;
    }
    for (const key of defKeys) {
      if (isDifferent(value[key], def[key])) {
        return true;
      }
    }
    return false;
  }
  return true;
}

function* chunk(arr, n) {
  if (!Array.isArray(arr)) {
    arr = [ ...arr ];
  }
  for (let i = 0; i < arr.length; i += n) {
    yield arr.slice(i, i + n);
  }
}

const textDecoder = new TextDecoder('utf-8');
const textEncoder = new TextEncoder();

// CoreVal tags shared across WasmExternBackend, ZigarCallbacksBackend, and --rpc-stdio:
//   0 = void, 1 = i32, 2 = i64, 3 = f32, 4 = f64
const CORE_VAL_VOID = 0;
const CORE_VAL_I32 = 1;
const CORE_VAL_I64 = 2;
const CORE_VAL_F32 = 3;
const CORE_VAL_F64 = 4;

const COMPONENT_HOST_REGISTRY_SYMBOL = Symbol.for('zigar.componentHosts');

/**
 * Shared per-process registry mapping numeric `instanceId` -> live `ComponentHost`
 * so `zigar-runtime` WASM modules can invoke `instantiateComponentHost(...)` instances
 * via `extern "zigar:component-host"` (`WasmExternBackend`) without custom loader glue.
 */
function getComponentHostRegistry() {
  let reg = globalThis[COMPONENT_HOST_REGISTRY_SYMBOL];
  if (!reg) {
    reg = {
      nextId: 1,
      hosts: new Map(),
    };
    Object.defineProperty(globalThis, COMPONENT_HOST_REGISTRY_SYMBOL, {
      value: reg,
      configurable: true,
      enumerable: false,
      writable: false,
    });
  }
  return reg;
}

// Binary RPC opcodes for native Zig <-> Node 26 V8 WebAssembly stdio bridge
const OP_ALLOC = 0x01;
const OP_WRITE = 0x02;
const OP_ALLOC_WRITE = 0x03;
const OP_READ = 0x04;
const OP_MEM_SIZE = 0x05;
const OP_CALL_CORE = 0x06;
const OP_POST_RETURN = 0x07;
const OP_RESOURCE_NEW = 0x08;
const OP_RESOURCE_REP = 0x09;
const OP_RESOURCE_DROP = 0x0a;
const OP_LIVE_RESOURCES = 0x0b;
const OP_SHUTDOWN = 0xff;

const RPC_MAGIC = [0x5a, 0x43, 0x48, 0x31]; // "ZCH1"

/**
 * Convert a signed 32-bit Wasm linear-memory pointer/offset into an unsigned
 * 32-bit JS integer (`0 .. 0xffff_ffff`), preventing negative-offset `RangeError`
 * when guest linear memory grows past 2 GiB (`0x8000_0000`, `nodejs/node#62671`).
 */
function toUnsignedPtr(ptr) {
  return Number(ptr) >>> 0;
}

/**
 * Create a bounds-checked `Uint8Array` view over `buffer` using unsigned 32-bit
 * pointer and length conversion safe across `>= 2 GiB` (`0x8000_0000+`) offsets.
 */
function sliceMemoryU8(buffer, ptr, len) {
  const start = toUnsignedPtr(ptr);
  const byteLength = toUnsignedPtr(len);
  if (start + byteLength > buffer.byteLength) {
    throw new RangeError(
      `Guest memory access out of bounds: offset=${start} len=${byteLength} size=${buffer.byteLength}`,
    );
  }
  return new Uint8Array(buffer, start, byteLength);
}

/**
 * Wrap a `wasi_snapshot_preview1` import object so every numeric Wasm `i32`
 * pointer/size argument is converted to unsigned `u32` (`>>> 0`) before invoking
 * Node's native WASI implementation, preserving `BigInt` `i64` parameters.
 */
function wrapWasiImportsUnsigned(rawWasi) {
  const wrapped = {};
  for (const [name, fn] of Object.entries(rawWasi)) {
    if (typeof fn === 'function') {
      wrapped[name] = (...args) =>
        fn(...args.map((arg) => (typeof arg === 'number' ? arg >>> 0 : arg)));
    } else {
      wrapped[name] = fn;
    }
  }
  if (typeof wrapped.fd_write === 'function' && !wrapped['fd_write [v2]']) {
    wrapped['fd_write [v2]'] = wrapped.fd_write;
  }
  if (!wrapped.adapter_monotonic_clock_set_paused) {
    wrapped.adapter_monotonic_clock_set_paused = () => {};
  }
  return wrapped;
}

function readULEB128(bytes, state) {
  let result = 0;
  let shift = 0;
  while (true) {
    if (state.pos >= bytes.length) {
      throw new Error('Unexpected EOF reading LEB128');
    }
    const byte = bytes[state.pos++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return result >>> 0;
    }
    shift += 7;
  }
}

function readSLEB128(bytes, state) {
  let result = 0;
  let shift = 0;
  let byte;
  do {
    if (state.pos >= bytes.length) {
      throw new Error('Unexpected EOF reading signed LEB128');
    }
    byte = bytes[state.pos++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  if (shift < 32 && (byte & 0x40) !== 0) {
    result |= (-1 << shift);
  }
  return result;
}

function readRawName(bytes, state) {
  const len = readULEB128(bytes, state);
  if (state.pos + len > bytes.length) {
    throw new Error('Unexpected EOF reading name');
  }
  const str = textDecoder.decode(bytes.subarray(state.pos, state.pos + len));
  state.pos += len;
  return str;
}

function readExternName(bytes, state) {
  const prefix = bytes[state.pos++];
  if (prefix > 0x02) {
    throw new Error(`Unsupported component externname prefix: 0x${prefix.toString(16)}`);
  }
  const name = readRawName(bytes, state);
  if (prefix === 0x02) {
    const attrCount = readULEB128(bytes, state);
    for (let i = 0; i < attrCount; i++) {
      state.pos++; // attr tag
      readRawName(bytes, state);
    }
  }
  return name;
}

function skipValType(bytes, state) {
  const raw = readSLEB128(bytes, state);
  if (raw < 0) {
    const tag = (raw + 0x80) & 0xff;
    // own (0x69) or borrow (0x68) carry a type index
    if (tag === 0x69 || tag === 0x68) {
      readULEB128(bytes, state);
    }
  }
}

function skipExternDesc(bytes, state) {
  const tag = bytes[state.pos++];
  switch (tag) {
    case 0x00: // core module: 0x11 <u32>
      state.pos++;
      readULEB128(bytes, state);
      break;
    case 0x01: // func: <u32>
    case 0x04: // component: <u32>
    case 0x05: // instance: <u32>
      readULEB128(bytes, state);
      break;
    case 0x02: // value: <valtype>
      skipValType(bytes, state);
      break;
    case 0x03: { // type: bound
      const boundTag = bytes[state.pos++];
      if (boundTag === 0x00) {
        readULEB128(bytes, state);
      }
      break;
    }
    default:
      throw new Error(`Unknown externdesc tag: 0x${tag.toString(16)}`);
  }
}

/**
 * Unpack a WebAssembly Component binary (`\0asm\x0d\x00\x01\x00`), extracting its
 * embedded core Wasm modules, core instance wiring plan, and top-level export names.
 */
function unpackComponent(componentSource) {
  const bytes = componentSource instanceof Uint8Array
    ? componentSource
    : new Uint8Array(componentSource);

  if (bytes.byteLength < 8) {
    throw new Error('Component binary too short');
  }
  const expectedPreamble = [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
  for (let i = 0; i < 8; i++) {
    if (bytes[i] !== expectedPreamble[i]) {
      throw new Error(`Invalid WebAssembly Component preamble at byte ${i}`);
    }
  }

  const coreModules = [];
  const coreInstances = [];
  const componentExports = [];
  const state = { pos: 8 };

  while (state.pos < bytes.byteLength) {
    const sectionId = bytes[state.pos++];
    const sectionSize = readULEB128(bytes, state);
    const sectionEnd = state.pos + sectionSize;
    if (sectionEnd > bytes.byteLength) {
      throw new Error('Component section exceeds binary length');
    }

    if (sectionId === 1) {
      // Core module section
      coreModules.push(bytes.subarray(state.pos, sectionEnd));
    } else if (sectionId === 2) {
      // Core instance section
      const inner = { pos: state.pos };
      const count = readULEB128(bytes, inner);
      for (let i = 0; i < count; i++) {
        const kindTag = bytes[inner.pos++];
        if (kindTag === 0x00) {
          const moduleIndex = readULEB128(bytes, inner);
          const argCount = readULEB128(bytes, inner);
          const args = [];
          for (let j = 0; j < argCount; j++) {
            const name = readRawName(bytes, inner);
            inner.pos++; // 0x12 instance sort
            const instanceIndex = readULEB128(bytes, inner);
            args.push({ name, instanceIndex });
          }
          coreInstances.push({ kind: 'instantiate', moduleIndex, args });
        } else if (kindTag === 0x01) {
          const expCount = readULEB128(bytes, inner);
          const exports = [];
          for (let j = 0; j < expCount; j++) {
            const name = readRawName(bytes, inner);
            const sort = bytes[inner.pos++];
            const index = readULEB128(bytes, inner);
            exports.push({ name, sort, index });
          }
          coreInstances.push({ kind: 'exports', exports });
        } else {
          throw new Error(`Invalid core instance tag: 0x${kindTag.toString(16)}`);
        }
      }
    } else if (sectionId === 11) {
      // Component export section
      const inner = { pos: state.pos };
      const count = readULEB128(bytes, inner);
      for (let i = 0; i < count; i++) {
        const exportName = readExternName(bytes, inner);
        const sort = bytes[inner.pos++];
        if (sort === 0x00) {
          inner.pos++; // core sub-sort
        }
        readULEB128(bytes, inner); // sort idx
        const hasDesc = bytes[inner.pos++];
        if (hasDesc === 0x01) {
          skipExternDesc(bytes, inner);
        }
        componentExports.push(exportName);
      }
    }

    state.pos = sectionEnd;
  }

  return {
    coreModules,
    coreInstances,
    componentExports,
  };
}

/**
 * Unified host handle table tracking live WIT resources (`own<T>` / `borrow<T>`)
 * across all exported interfaces of a component instance.
 */
class HostResourceTable {
  #nextHandle = 1;
  #entries = new Map();
  #dtors = new Map();
  mutationEpoch = 0;

  bindDtor(iface, resourceName, dtorFn) {
    if (typeof dtorFn !== 'function') return;
    if (iface) {
      this.#dtors.set(`${iface}#${resourceName}`, dtorFn);
    }
    if (!this.#dtors.has(resourceName)) {
      this.#dtors.set(resourceName, dtorFn);
    }
  }

  insert(iface, resourceName, rep) {
    const handle = this.#nextHandle++;
    this.#entries.set(handle, {
      iface: iface || '',
      resourceName,
      rep: toUnsignedPtr(rep),
    });
    this.mutationEpoch = (this.mutationEpoch + 1) >>> 0;
    return handle;
  }

  rep(iface, resourceName, handle) {
    const h = handle | 0;
    const entry = this.#entries.get(h);
    if (!entry) {
      throw new Error(`Invalid or dropped resource handle: ${h} (${resourceName || 'unknown'})`);
    }
    if (resourceName && entry.resourceName !== resourceName) {
      throw new Error(
        `Resource handle type mismatch for handle ${h}: expected '${resourceName}', found '${entry.resourceName}'`,
      );
    }
    return entry.rep | 0;
  }

  has(handle) {
    return this.#entries.has(handle | 0);
  }

  drop(iface, resourceName, handle) {
    const h = handle | 0;
    const entry = this.#entries.get(h);
    if (!entry) {
      throw new Error(`Double-drop or invalid resource handle: ${h} (${resourceName || 'unknown'})`);
    }
    if (resourceName && entry.resourceName !== resourceName) {
      throw new Error(
        `Resource handle type mismatch on drop for handle ${h}: expected '${resourceName}', found '${entry.resourceName}'`,
      );
    }
    this.#entries.delete(h);
    this.mutationEpoch = (this.mutationEpoch + 1) >>> 0;
    const dtor = this.#dtors.get(`${entry.iface}#${entry.resourceName}`) ??
      this.#dtors.get(entry.resourceName);
    if (dtor) {
      dtor(entry.rep | 0);
    }
  }

  get liveCount() {
    return this.#entries.size;
  }
}

function createResourceImportModule(resourceTable, ifaceName) {
  const cache = new Map();
  return new Proxy(
    {},
    {
      get(_target, prop) {
        if (typeof prop !== 'string') return undefined;
        let fn = cache.get(prop);
        if (fn) return fn;
        if (prop.startsWith('[resource-new]')) {
          const resName = prop.slice('[resource-new]'.length);
          fn = (rep) => resourceTable.insert(ifaceName, resName, rep);
        } else if (prop.startsWith('[resource-rep]')) {
          const resName = prop.slice('[resource-rep]'.length);
          fn = (handle) => resourceTable.rep(ifaceName, resName, handle);
        } else if (prop.startsWith('[resource-drop]')) {
          const resName = prop.slice('[resource-drop]'.length);
          fn = (handle) => resourceTable.drop(ifaceName, resName, handle);
        }
        if (fn) cache.set(prop, fn);
        return fn;
      },
    },
  );
}

const f32ScratchBuf = new ArrayBuffer(8);
const f32ScratchDV = new DataView(f32ScratchBuf);

function coreValToJsArg(tag, bitsBigInt) {
  switch (tag) {
    case CORE_VAL_I32:
      return Number(BigInt.asIntN(32, bitsBigInt));
    case CORE_VAL_I64:
      return BigInt.asIntN(64, bitsBigInt);
    case CORE_VAL_F32:
      f32ScratchDV.setUint32(0, Number(bitsBigInt & 0xffff_ffffn) >>> 0, true);
      return f32ScratchDV.getFloat32(0, true);
    case CORE_VAL_F64:
      f32ScratchDV.setBigUint64(0, BigInt.asUintN(64, bitsBigInt), true);
      return f32ScratchDV.getFloat64(0, true);
    default:
      throw new Error(`Invalid CoreVal tag: ${tag}`);
  }
}

function jsRetToCoreVal(raw, expectedRetTag) {
  if (expectedRetTag === CORE_VAL_VOID || raw === undefined) {
    return { tag: CORE_VAL_VOID, bits: 0n };
  }
  if (expectedRetTag === CORE_VAL_I64 || typeof raw === 'bigint') {
    return { tag: CORE_VAL_I64, bits: BigInt.asUintN(64, BigInt(raw)) };
  }
  if (expectedRetTag === CORE_VAL_F32) {
    f32ScratchDV.setFloat32(0, Number(raw), true);
    return { tag: CORE_VAL_F32, bits: BigInt(f32ScratchDV.getUint32(0, true)) };
  }
  if (expectedRetTag === CORE_VAL_F64) {
    f32ScratchDV.setFloat64(0, Number(raw), true);
    return { tag: CORE_VAL_F64, bits: f32ScratchDV.getBigUint64(0, true) };
  }
  return { tag: CORE_VAL_I32, bits: BigInt(Number(raw) >>> 0) };
}

/**
 * Instantiate a WebAssembly Component (`.component.wasm` produced by `componentize-go`
 * or WASI P1 reactor adapters) in Node.js 26 / V8 WebAssembly with:
 *   - Unsigned `>>> 0` WASI P1 pointer wrapping (`>= 2 GiB` linear memory safe),
 *   - Automatic `[export]<iface>` `[resource-new]` / `[resource-rep]` / `[resource-drop]`
 *     and `<iface>#[dtor]<res>` wiring,
 *   - Cross-memory Canonical ABI host primitives (`alloc`, `read`, `write`, `callCore`,
 *     `callPostReturn`, `createWasmImports`, `createZigarCallbacks`).
 */
function instantiateComponentHost(wasmSourceOrPath, options = {}) {
  let componentBytes;
  if (typeof wasmSourceOrPath === 'string' || wasmSourceOrPath instanceof URL) {
    componentBytes = node_fs.readFileSync(wasmSourceOrPath);
  } else if (wasmSourceOrPath instanceof Uint8Array) {
    componentBytes = wasmSourceOrPath;
  } else if (wasmSourceOrPath instanceof ArrayBuffer || ArrayBuffer.isView(wasmSourceOrPath)) {
    componentBytes = wasmSourceOrPath instanceof ArrayBuffer
      ? new Uint8Array(wasmSourceOrPath)
      : new Uint8Array(
        wasmSourceOrPath.buffer,
        wasmSourceOrPath.byteOffset,
        wasmSourceOrPath.byteLength,
      );
  } else {
    throw new TypeError('Expected file path, URL, Uint8Array, or ArrayBuffer for wasmSourceOrPath');
  }

  const unpacked = unpackComponent(componentBytes);
  if (unpacked.coreModules.length === 0) {
    throw new Error('Component contains no embedded core Wasm modules');
  }

  const compiledModules = unpacked.coreModules.map((bytes) => new WebAssembly.Module(bytes));

  // Locate primary guest reactor module (exports `memory` and `cabi_realloc` or `_initialize`)
  let primaryModuleIndex = 0;
  for (let i = 0; i < compiledModules.length; i++) {
    const exps = WebAssembly.Module.exports(compiledModules[i]);
    const hasMem = exps.some((e) => e.kind === 'memory' && e.name === 'memory');
    const hasReallocOrInit = exps.some(
      (e) => e.kind === 'function' && (e.name === 'cabi_realloc' || e.name === '_initialize'),
    );
    if (hasMem && hasReallocOrInit) {
      primaryModuleIndex = i;
      break;
    }
  }

  const wasiOptions = {
    version: 'preview1',
    ...(options.rpcStdio ? { stdout: 2, stderr: 2 } : {}),
    ...(options.wasiOptions || {}),
  };
  const wasi = new node_wasi.WASI(wasiOptions);
  const wrappedWasi = wrapWasiImportsUnsigned(wasi.wasiImport);
  const resourceTable = new HostResourceTable();

  const primaryMod = compiledModules[primaryModuleIndex];
  const importObject = { ...(options.imports || {}) };
  let usesWasi = false;

  // Check if helper table/shim modules exist in `coreInstances` for indirect imports
  const helperExportsByModule = new Map();
  for (let i = 0; i < compiledModules.length; i++) {
    if (i === primaryModuleIndex) continue;
    const modImports = WebAssembly.Module.imports(compiledModules[i]);
    if (modImports.length === 0) {
      const helperInstance = new WebAssembly.Instance(compiledModules[i], {});
      helperExportsByModule.set(i, helperInstance.exports);
    }
  }

  for (const imp of WebAssembly.Module.imports(primaryMod)) {
    if (imp.module === 'wasi_snapshot_preview1') {
      usesWasi = true;
      importObject.wasi_snapshot_preview1 = wrappedWasi;
    } else if (imp.module.startsWith('[export]')) {
      const ifaceName = imp.module.slice('[export]'.length);
      if (!importObject[imp.module]) {
        importObject[imp.module] = createResourceImportModule(resourceTable, ifaceName);
      }
    } else if (!importObject[imp.module]) {
      // Resolve from any zero-import helper table/shim module (e.g. `""` `$imports`)
      for (const helperExps of helperExportsByModule.values()) {
        if (imp.name in helperExps) {
          importObject[imp.module] ??= {};
          importObject[imp.module][imp.name] = helperExps[imp.name];
        }
      }
    }
  }

  const instance = new WebAssembly.Instance(primaryMod, importObject);
  const exp = instance.exports;

  // Bind all exported resource destructors (`<iface>#[dtor]<res>` or `[dtor]<res>`)
  for (const [expName, expVal] of Object.entries(exp)) {
    if (typeof expVal !== 'function') continue;
    const dtorIdx = expName.indexOf('#[dtor]');
    if (dtorIdx !== -1) {
      const iface = expName.slice(0, dtorIdx);
      const resName = expName.slice(dtorIdx + '#[dtor]'.length);
      resourceTable.bindDtor(iface, resName, expVal);
    } else if (expName.startsWith('[dtor]')) {
      const resName = expName.slice('[dtor]'.length);
      resourceTable.bindDtor('', resName, expVal);
    }
  }

  if (usesWasi && typeof exp._initialize === 'function') {
    wasi.initialize(instance);
  } else if (typeof exp._initialize === 'function') {
    exp._initialize();
  }

  const registry = getComponentHostRegistry();
  const instanceId = (
    options.instanceId !== undefined
      ? options.instanceId
      : options.register === false
        ? 0
        : registry.nextId++
  ) >>> 0;

  const host = {
    instanceId,
    unpacked,
    instance,
    exports: exp,
    resourceTable,

    dispose() {
      registry.hosts.delete(instanceId);
    },

    close() {
      registry.hosts.delete(instanceId);
    },

    get memory() {
      return exp.memory;
    },

    memoryByteLength() {
      return exp.memory.buffer.byteLength;
    },

    alloc(reallocExportName = 'cabi_realloc', align = 1, byteLen = 0) {
      const a = align >>> 0;
      const len = byteLen >>> 0;
      if (a === 0 || (a & (a - 1)) !== 0) {
        throw new Error(`Invalid Canonical ABI alignment: ${a}`);
      }
      if (len === 0) {
        return a;
      }
      const reallocFn = exp[reallocExportName || 'cabi_realloc'];
      if (typeof reallocFn !== 'function') {
        throw new Error(`Missing guest realloc export: ${reallocExportName}`);
      }
      const ptr = toUnsignedPtr(reallocFn(0, 0, a, len));
      if (a > 1 && (ptr % a) !== 0) {
        throw new Error(`Unaligned pointer returned by ${reallocExportName}: 0x${ptr.toString(16)} (align ${a})`);
      }
      if (ptr + len > exp.memory.buffer.byteLength) {
        throw new RangeError(
          `Pointer returned by ${reallocExportName} out of bounds: ptr=${ptr} len=${len} mem=${exp.memory.buffer.byteLength}`,
        );
      }
      return ptr;
    },

    write(guestAddr, srcBytes) {
      if (srcBytes.byteLength === 0) {
        const addr = toUnsignedPtr(guestAddr);
        if (addr > exp.memory.buffer.byteLength) {
          throw new RangeError(`Write address out of bounds: ${addr} > ${exp.memory.buffer.byteLength}`);
        }
        return;
      }
      sliceMemoryU8(exp.memory.buffer, guestAddr, srcBytes.byteLength).set(srcBytes);
    },

    allocAndWrite(reallocExportName, align, srcBytes) {
      const ptr = this.alloc(reallocExportName, align, srcBytes.byteLength);
      if (srcBytes.byteLength > 0) {
        sliceMemoryU8(exp.memory.buffer, ptr, srcBytes.byteLength).set(srcBytes);
      }
      return ptr;
    },

    read(guestAddr, byteLen) {
      return sliceMemoryU8(exp.memory.buffer, guestAddr, byteLen);
    },

    readCopy(guestAddr, byteLen) {
      return sliceMemoryU8(exp.memory.buffer, guestAddr, byteLen).slice();
    },

    callCore(exportName, params = [], expectedRetTag = CORE_VAL_VOID) {
      const fn = exp[exportName];
      if (typeof fn !== 'function') {
        throw new Error(`Missing guest core export: ${exportName}`);
      }
      const jsArgs = new Array(params.length);
      for (let i = 0; i < params.length; i++) {
        jsArgs[i] = coreValToJsArg(params[i].tag, BigInt(params[i].bits));
      }
      const raw = fn(...jsArgs);
      return jsRetToCoreVal(raw, expectedRetTag);
    },

    callPostReturn(postExportName, valTag, valBits) {
      const fn = exp[postExportName];
      if (typeof fn !== 'function') {
        throw new Error(`Missing guest post-return export: ${postExportName}`);
      }
      if (valTag === CORE_VAL_VOID) {
        fn();
      } else {
        fn(coreValToJsArg(valTag, BigInt(valBits)));
      }
    },

    resourceNew(iface, resourceName, rep) {
      return resourceTable.insert(iface, resourceName, rep);
    },

    resourceRep(iface, resourceName, handle) {
      return resourceTable.rep(iface, resourceName, handle);
    },

    resourceDrop(iface, resourceName, handle) {
      resourceTable.drop(iface, resourceName, handle);
    },

    liveResourceCount() {
      return resourceTable.liveCount;
    },

    /**
     * Create `"zigar:component-host"` WebAssembly imports connecting a WASM-compiled
     * Zig module (`WasmExternBackend` in `wit-zigar/src/component_host.zig`) directly
     * to this component instance in V8 with zero serialization overhead.
     *
     * @param {() => WebAssembly.Memory} getCallerMemory Returns the Zig caller's `WebAssembly.Memory`
     */
    createWasmImports(getCallerMemory) {
      return createComponentHostWasmImports(
        new Map([
          [1, host],
          [instanceId, host],
        ]),
        getCallerMemory,
      );
    },

    /**
     * Create JS callback functions matching `ZigarCallbacks` in
     * `wit-zigar/src/component_host.zig` so any `zigar` module (WASM via `zigar-compiler`
     * or native via `node-zigar`) can drive this component instance directly.
     */
    createZigarCallbacks() {
      const toU8 = (val) => {
        if (val instanceof Uint8Array) return val;
        if (val?.typedArray instanceof Uint8Array) return val.typedArray;
        if (val?.dataView instanceof DataView) {
          return new Uint8Array(val.dataView.buffer, val.dataView.byteOffset, val.dataView.byteLength);
        }
        if (ArrayBuffer.isView(val)) {
          return new Uint8Array(val.buffer, val.byteOffset, val.byteLength);
        }
        if (val instanceof ArrayBuffer) return new Uint8Array(val);
        if (typeof val === 'string') return textEncoder.encode(val);
        return Uint8Array.from(val ?? []);
      };
      const toStr = (val) => {
        if (typeof val === 'string') return val;
        if (typeof val?.string === 'string') return val.string;
        return textDecoder.decode(toU8(val));
      };
      return {
        alloc: (reallocNameBytes, alignBytes, byteLen) => {
          try {
            return BigInt(host.alloc(toStr(reallocNameBytes), Number(alignBytes) >>> 0, Number(byteLen) >>> 0));
          } catch {
            return -1n;
          }
        },
        write: (guestAddr, dataBytes) => {
          try {
            host.write(Number(guestAddr) >>> 0, toU8(dataBytes));
            return true;
          } catch {
            return false;
          }
        },
        read_chunk: (guestAddr, byteLen) => {
          const data = new Uint8Array(4096);
          try {
            const n = Math.min(Number(byteLen) >>> 0, 4096);
            const view = host.read(Number(guestAddr) >>> 0, n);
            data.set(view);
            return { status: 1, len: n, data };
          } catch {
            return { status: 0, len: 0, data };
          }
        },
        memory_size: () => BigInt(host.memoryByteLength()),
        call_core: (exportNameBytes, encodedParams, expectedRetTag) => {
          try {
            const name = toStr(exportNameBytes);
            const paramBytes = toU8(encodedParams);
            const dv = new DataView(paramBytes.buffer, paramBytes.byteOffset, paramBytes.byteLength);
            const count = (paramBytes.byteLength / 16) >>> 0;
            const params = new Array(count);
            for (let i = 0; i < count; i++) {
              const tag = dv.getUint32(i * 16, true);
              const bits = dv.getBigUint64(i * 16 + 8, true);
              params[i] = { tag, bits };
            }
            const res = host.callCore(name, params, Number(expectedRetTag) >>> 0);
            return {
              status: 1,
              tag: res.tag >>> 0,
              bits: res.bits,
            };
          } catch {
            return { status: 0, tag: 0, bits: 0n };
          }
        },
        call_post_return: (exportNameBytes, valTag, valBits) => {
          try {
            host.callPostReturn(toStr(exportNameBytes), Number(valTag) >>> 0, BigInt(valBits));
            return true;
          } catch {
            return false;
          }
        },
        resource_new: (ifaceBytes, resBytes, rep) => {
          return host.resourceNew(toStr(ifaceBytes), toStr(resBytes), Number(rep) | 0);
        },
        resource_rep: (ifaceBytes, resBytes, handle) => {
          try {
            const rep = host.resourceRep(toStr(ifaceBytes), toStr(resBytes), Number(handle) | 0);
            return BigInt(rep >>> 0);
          } catch {
            return -1n;
          }
        },
        resource_drop: (ifaceBytes, resBytes, handle) => {
          try {
            host.resourceDrop(toStr(ifaceBytes), toStr(resBytes), Number(handle) | 0);
            return true;
          } catch {
            return false;
          }
        },
        live_resource_count: () => host.liveResourceCount() >>> 0,
      };
    },
  };

  if (options.register !== false) {
    registry.hosts.set(instanceId, host);
  }

  return host;
}

/**
 * Build `"zigar:component-host"` WebAssembly import bindings for one or more
 * `ComponentHost` instances keyed by numeric `instId` (defaults to the shared
 * `getComponentHostRegistry().hosts` map when `hostsById` is null/undefined).
 */
function createComponentHostWasmImports(hostsById, getCallerMemory) {
  const sourceMapOrObj = hostsById ?? getComponentHostRegistry().hosts;
  const resolveHost = (instId) => {
    const id = instId >>> 0;
    const h = sourceMapOrObj instanceof Map ? sourceMapOrObj.get(id) : sourceMapOrObj[id];
    if (!h) {
      throw new Error(`Unknown component host instance id: ${id}`);
    }
    return h;
  };

  const callerBytes = (ptr, len) => {
    const mem = getCallerMemory();
    return sliceMemoryU8(mem.buffer, ptr, len);
  };

  const callerStr = (ptr, len) => textDecoder.decode(callerBytes(ptr, len));

  return {
    'zigar:component-host': {
      // Returns status (0 = ok, non-zero = error); writes u32 guest addr to out_addr_ptr
      alloc(instId, reallocPtr, reallocLen, alignBytes, byteLen, outAddrPtr) {
        try {
          const h = resolveHost(instId);
          const reallocName = callerStr(reallocPtr, reallocLen);
          const addr = h.alloc(reallocName, alignBytes >>> 0, byteLen >>> 0);
          const mem = getCallerMemory();
          new DataView(mem.buffer, toUnsignedPtr(outAddrPtr), 4).setUint32(0, addr >>> 0, true);
          return 0;
        } catch {
          return 1;
        }
      },

      write(instId, guestAddr, srcPtr, byteLen) {
        try {
          const h = resolveHost(instId);
          const src = callerBytes(srcPtr, byteLen);
          h.write(guestAddr >>> 0, src);
          return 0;
        } catch {
          return 1;
        }
      },

      read(instId, guestAddr, dstPtr, byteLen) {
        try {
          const h = resolveHost(instId);
          const src = h.read(guestAddr >>> 0, byteLen >>> 0);
          const dst = callerBytes(dstPtr, byteLen);
          dst.set(src);
          return 0;
        } catch {
          return 1;
        }
      },

      memory_size(instId) {
        const h = resolveHost(instId);
        return BigInt(h.memoryByteLength());
      },

      // params_ptr: `params_count` entries of 16 bytes `[tag: u32, pad: u32, bits: u64]`
      // result_ptr: 16 bytes `[tag: u32, pad: u32, bits: u64]`
      call_core(instId, expPtr, expLen, paramsPtr, paramsCount, expectedRetTag, resultPtr) {
        try {
          const h = resolveHost(instId);
          const expName = callerStr(expPtr, expLen);
          const count = paramsCount >>> 0;
          const params = new Array(count);
          if (count > 0) {
            const mem = getCallerMemory();
            const dv = new DataView(mem.buffer, toUnsignedPtr(paramsPtr), count * 16);
            for (let i = 0; i < count; i++) {
              params[i] = {
                tag: dv.getUint32(i * 16, true),
                bits: dv.getBigUint64(i * 16 + 8, true),
              };
            }
          }
          const res = h.callCore(expName, params, expectedRetTag >>> 0);
          const mem = getCallerMemory();
          const resDV = new DataView(mem.buffer, toUnsignedPtr(resultPtr), 16);
          resDV.setUint32(0, res.tag >>> 0, true);
          resDV.setUint32(4, 0, true);
          resDV.setBigUint64(8, res.bits, true);
          return 0;
        } catch {
          return 1;
        }
      },

      call_post_return(instId, expPtr, expLen, valTag, valBits) {
        try {
          const h = resolveHost(instId);
          const expName = callerStr(expPtr, expLen);
          h.callPostReturn(expName, valTag >>> 0, BigInt.asUintN(64, BigInt(valBits)));
          return 0;
        } catch {
          return 1;
        }
      },

      resource_new(instId, ifacePtr, ifaceLen, resPtr, resLen, rep) {
        try {
          const h = resolveHost(instId);
          return h.resourceNew(callerStr(ifacePtr, ifaceLen), callerStr(resPtr, resLen), rep | 0);
        } catch {
          return -1;
        }
      },

      resource_rep(instId, ifacePtr, ifaceLen, resPtr, resLen, handle, outRepPtr) {
        try {
          const h = resolveHost(instId);
          const rep = h.resourceRep(callerStr(ifacePtr, ifaceLen), callerStr(resPtr, resLen), handle | 0);
          const mem = getCallerMemory();
          new DataView(mem.buffer, toUnsignedPtr(outRepPtr), 4).setInt32(0, rep | 0, true);
          return 0;
        } catch {
          return 1;
        }
      },

      resource_drop(instId, ifacePtr, ifaceLen, resPtr, resLen, handle) {
        try {
          const h = resolveHost(instId);
          h.resourceDrop(callerStr(ifacePtr, ifaceLen), callerStr(resPtr, resLen), handle | 0);
          return 0;
        } catch {
          return 1;
        }
      },

      live_resource_count(instId) {
        const h = resolveHost(instId);
        return h.liveResourceCount() >>> 0;
      },
    },
  };
}

// ── Binary-Framed Stdio RPC Worker (`--rpc-stdio <component.wasm>`) ─────────

function readExactSync(fd, targetBuf, length) {
  let offset = 0;
  while (offset < length) {
    let n = 0;
    try {
      n = node_fs.readSync(fd, targetBuf, offset, length - offset, null);
    } catch (err) {
      if (err && (err.code === 'EAGAIN' || err.code === 'EINTR')) {
        continue;
      }
      throw err;
    }
    if (n === 0) {
      if (offset === 0) return false;
      throw new Error('Unexpected EOF on component-host RPC stdin');
    }
    offset += n;
  }
  return true;
}

function writeAllSync(fd, buf, offset, length) {
  let pos = offset;
  const end = offset + length;
  while (pos < end) {
    try {
      const n = node_fs.writeSync(fd, buf, pos, end - pos);
      pos += n;
    } catch (err) {
      if (err && (err.code === 'EAGAIN' || err.code === 'EINTR')) {
        continue;
      }
      throw err;
    }
  }
}

function runComponentHostRpcStdio(wasmPath) {
  const handshake = new Uint8Array(16);
  const handshakeDV = new DataView(handshake.buffer);
  handshake.set(RPC_MAGIC, 0);

  let host;
  try {
    host = instantiateComponentHost(wasmPath, { rpcStdio: true });
  } catch (err) {
    const msg = textEncoder.encode(err instanceof Error ? err.message : String(err));
    handshakeDV.setUint32(4, 1, true);
    handshakeDV.setBigUint64(8, BigInt(msg.byteLength), true);
    writeAllSync(1, handshake, 0, 16);
    if (msg.byteLength > 0) {
      writeAllSync(1, msg, 0, msg.byteLength);
    }
    process.exit(1);
  }

  handshakeDV.setUint32(4, 0, true);
  handshakeDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
  writeAllSync(1, handshake, 0, 16);

  const reqHeader = new Uint8Array(8);
  const reqHeaderDV = new DataView(reqHeader.buffer);
  let payloadBuf = new Uint8Array(65536);

  const respFixed = new Uint8Array(32);
  const respFixedDV = new DataView(respFixed.buffer);

  const sendOk = (valTag, flags, payloadBytes, payloadLen) => {
    respFixed[0] = 0;
    respFixed[1] = valTag & 0xff;
    respFixedDV.setUint16(2, flags & 0xffff, true);
    respFixedDV.setUint32(4, payloadLen >>> 0, true);
    if (payloadLen === 0) {
      writeAllSync(1, respFixed, 0, 8);
    } else if (payloadBytes === respFixed) {
      writeAllSync(1, respFixed, 0, 8 + payloadLen);
    } else {
      writeAllSync(1, respFixed, 0, 8);
      writeAllSync(1, payloadBytes, 0, payloadLen);
    }
  };

  const sendErr = (code, err) => {
    const msg = textEncoder.encode(err instanceof Error ? err.message : String(err));
    respFixed[0] = code & 0xff;
    respFixed[1] = 0;
    respFixedDV.setUint16(2, 0, true);
    respFixedDV.setUint32(4, msg.byteLength >>> 0, true);
    writeAllSync(1, respFixed, 0, 8);
    if (msg.byteLength > 0) {
      writeAllSync(1, msg, 0, msg.byteLength);
    }
  };

  while (readExactSync(0, reqHeader, 8)) {
    const opcode = reqHeader[0];
    const reqFlags = reqHeader[1];
    const payloadLen = reqHeaderDV.getUint32(4, true);

    if (payloadLen > payloadBuf.byteLength) {
      let nextCap = payloadBuf.byteLength;
      while (nextCap < payloadLen) nextCap *= 2;
      payloadBuf = new Uint8Array(nextCap);
    }
    if (payloadLen > 0) {
      if (!readExactSync(0, payloadBuf, payloadLen)) break;
    }
    const payload = payloadBuf.subarray(0, payloadLen);
    const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);

    try {
      switch (opcode) {
        case OP_ALLOC: {
          const align = dv.getUint32(0, true);
          const byteLen = dv.getUint32(4, true);
          const reallocName = textDecoder.decode(payload.subarray(8, payloadLen));
          const addr = host.alloc(reallocName, align, byteLen);
          respFixedDV.setUint32(8, addr >>> 0, true);
          respFixedDV.setBigUint64(12, BigInt(host.memoryByteLength()), true);
          sendOk(0, 0, respFixed, 12);
          break;
        }
        case OP_WRITE: {
          const guestAddr = dv.getUint32(0, true);
          host.write(guestAddr, payload.subarray(4, payloadLen));
          sendOk(0, 0, respFixed, 0);
          break;
        }
        case OP_ALLOC_WRITE: {
          const align = dv.getUint32(0, true);
          const nameLen = dv.getUint16(4, true);
          const reallocName = textDecoder.decode(payload.subarray(8, 8 + nameLen));
          const data = payload.subarray(8 + nameLen, payloadLen);
          const addr = host.allocAndWrite(reallocName, align, data);
          respFixedDV.setUint32(8, addr >>> 0, true);
          respFixedDV.setBigUint64(12, BigInt(host.memoryByteLength()), true);
          sendOk(0, 0, respFixed, 12);
          break;
        }
        case OP_READ: {
          const guestAddr = dv.getUint32(0, true);
          const byteLen = dv.getUint32(4, true);
          const view = host.read(guestAddr, byteLen);
          respFixed[0] = 0;
          respFixed[1] = 0;
          respFixedDV.setUint16(2, 0, true);
          respFixedDV.setUint32(4, (8 + view.byteLength) >>> 0, true);
          respFixedDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
          writeAllSync(1, respFixed, 0, 16);
          if (view.byteLength > 0) {
            writeAllSync(1, view, 0, view.byteLength);
          }
          break;
        }
        case OP_MEM_SIZE: {
          respFixedDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
          sendOk(0, 0, respFixed, 8);
          break;
        }
        case OP_CALL_CORE: {
          const nameLen = dv.getUint16(0, true);
          const paramCount = dv.getUint16(2, true);
          const exportName = textDecoder.decode(payload.subarray(4, 4 + nameLen));
          const paramsOffset = 4 + nameLen;
          const params = new Array(paramCount);
          for (let i = 0; i < paramCount; i++) {
            const base = paramsOffset + i * 12;
            const tag = payload[base];
            const bits = dv.getBigUint64(base + 4, true);
            params[i] = { tag, bits };
          }
          const epochBefore = host.resourceTable.mutationEpoch;
          const res = host.callCore(exportName, params, reqFlags);
          const epochAfter = host.resourceTable.mutationEpoch;
          const outFlags = epochBefore !== epochAfter ? 1 : 0;
          respFixedDV.setBigUint64(8, res.bits, true);
          respFixedDV.setBigUint64(16, BigInt(host.memoryByteLength()), true);
          respFixedDV.setUint32(24, host.liveResourceCount() >>> 0, true);
          sendOk(res.tag, outFlags, respFixed, 20);
          break;
        }
        case OP_POST_RETURN: {
          const valTag = payload[0];
          const valBits = dv.getBigUint64(4, true);
          const postExportName = textDecoder.decode(payload.subarray(12, payloadLen));
          const epochBefore = host.resourceTable.mutationEpoch;
          host.callPostReturn(postExportName, valTag, valBits);
          const epochAfter = host.resourceTable.mutationEpoch;
          const outFlags = epochBefore !== epochAfter ? 1 : 0;
          respFixedDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
          respFixedDV.setUint32(16, host.liveResourceCount() >>> 0, true);
          sendOk(0, outFlags, respFixed, 12);
          break;
        }
        case OP_RESOURCE_NEW: {
          const rep = dv.getInt32(0, true);
          const ifaceLen = dv.getUint16(4, true);
          const resLen = dv.getUint16(6, true);
          const iface = textDecoder.decode(payload.subarray(8, 8 + ifaceLen));
          const resName = textDecoder.decode(payload.subarray(8 + ifaceLen, 8 + ifaceLen + resLen));
          const handle = host.resourceNew(iface, resName, rep);
          respFixedDV.setInt32(8, handle | 0, true);
          respFixedDV.setUint32(12, host.liveResourceCount() >>> 0, true);
          sendOk(0, 1, respFixed, 8);
          break;
        }
        case OP_RESOURCE_REP: {
          const handle = dv.getInt32(0, true);
          const ifaceLen = dv.getUint16(4, true);
          const resLen = dv.getUint16(6, true);
          const iface = textDecoder.decode(payload.subarray(8, 8 + ifaceLen));
          const resName = textDecoder.decode(payload.subarray(8 + ifaceLen, 8 + ifaceLen + resLen));
          const rep = host.resourceRep(iface, resName, handle);
          respFixedDV.setInt32(8, rep | 0, true);
          sendOk(0, 0, respFixed, 4);
          break;
        }
        case OP_RESOURCE_DROP: {
          const handle = dv.getInt32(0, true);
          const ifaceLen = dv.getUint16(4, true);
          const resLen = dv.getUint16(6, true);
          const iface = textDecoder.decode(payload.subarray(8, 8 + ifaceLen));
          const resName = textDecoder.decode(payload.subarray(8 + ifaceLen, 8 + ifaceLen + resLen));
          host.resourceDrop(iface, resName, handle);
          respFixedDV.setUint32(8, host.liveResourceCount() >>> 0, true);
          sendOk(0, 1, respFixed, 4);
          break;
        }
        case OP_LIVE_RESOURCES: {
          respFixedDV.setUint32(8, host.liveResourceCount() >>> 0, true);
          sendOk(0, 0, respFixed, 4);
          break;
        }
        case OP_SHUTDOWN: {
          sendOk(0, 0, respFixed, 0);
          try {
            node_fs.closeSync(0);
          } catch {}
          return;
        }
        default:
          throw new Error(`Unknown RPC opcode: 0x${opcode.toString(16)}`);
      }
    } catch (err) {
      sendErr(1, err);
    }
  }
}

if (
  typeof process !== 'undefined' &&
  Array.isArray(process.argv) &&
  (process.argv[1] === '--rpc-stdio' ||
    (typeof process.argv[1] === 'string' &&
      (process.argv[1].endsWith('component-host.js') ||
        process.argv[1].endsWith('node_rpc_worker.mjs'))))
) {
  const rpcIdx = process.argv.indexOf('--rpc-stdio');
  if (rpcIdx !== -1 && rpcIdx + 1 < process.argv.length) {
    runComponentHostRpcStdio(process.argv[rpcIdx + 1]);
  }
}

const MagicNumber = 0x6d736100;
const Version = 1;
const SectionType = {
  Custom: 0,
  Type: 1,
  Import: 2,
  Function: 3,
  Global: 6,
  Export: 7,
  Start: 8,
  Element: 9,
  Code: 10};
const ObjectType = {
  Function: 0,
  Table: 1,
  Memory: 2,
  Global: 3,
};

function fixWasm64TlsGlobals(binary) {
  const { sections, size } = parseBinary(binary);
  const typeSection = sections.find(s => s.type === SectionType.Type);
  const importSection = sections.find(s => s.type === SectionType.Import);
  const funcSection = sections.find(s => s.type === SectionType.Function);
  const globalSection = sections.find(s => s.type === SectionType.Global);
  const codeSection = sections.find(s => s.type === SectionType.Code);
  if (!typeSection || !funcSection || !globalSection || !codeSection) {
    return binary;
  }
  const globalTypes = [];
  if (importSection) {
    for (const imp of importSection.imports) {
      if (imp.type === ObjectType.Global) {
        globalTypes.push({ valtype: imp.valtype, mut: imp.mut });
      }
    }
  }
  {
    const reader = createReader(globalSection.data);
    const count = reader.readU32Leb128();
    for (let i = 0; i < count; i++) {
      const valtype = reader.readU8();
      const mut = reader.readU8();
      reader.readExpression();
      globalTypes.push({ valtype, mut });
    }
  }
  if (!globalTypes.some(g => g.valtype === 0x7e && g.mut === 0)) {
    return binary;
  }
  const funcParams = [];
  {
    const reader = createReader(typeSection.data);
    const count = reader.readU32Leb128();
    for (let i = 0; i < count; i++) {
      const form = reader.readU8();
      if (form !== 0x60) return binary;
      const params = reader.readArray(reader.readU8);
      reader.readArray(reader.readU8);
      funcParams.push(params);
    }
  }
  let patched = 0;
  for (let i = 0; i < codeSection.functions.length; i++) {
    const code = codeSection.functions[i];
    let hasGlobalGet = false;
    for (let b = 0; b < code.byteLength; b++) {
      if (code.getUint8(b) === 0x23) {
        hasGlobalGet = true;
        break;
      }
    }
    if (!hasGlobalGet) continue;
    const parsed = parseFunction(code);
    const params = funcParams[funcSection.types[i]] ?? [];
    let localTypes = null;
    const getLocalType = (idx) => {
      if (!localTypes) {
        localTypes = [ ...params ];
        for (const { number, type } of parsed.locals) {
          for (let k = 0; k < number; k++) {
            localTypes.push(type);
          }
        }
      }
      return localTypes[idx];
    };
    const ops = parsed.instructions;
    let fnModified = false;
    const newOps = [];
    for (let j = 0; j < ops.length; j++) {
      const op = ops[j];
      newOps.push(op);
      if (op.opcode === 0x23) {
        const g = globalTypes[op.operand];
        const next = ops[j + 1];
        if (g && g.valtype === 0x7e && g.mut === 0 && next) {
          const expectsI32 = next.opcode === 0xAC || next.opcode === 0xAD
            || ((next.opcode === 0x21 || next.opcode === 0x22) && getLocalType(next.operand) === 0x7f);
          if (expectsI32) {
            newOps.push({ opcode: 0xA7, operand: undefined });
            fnModified = true;
            patched++;
          }
        }
      }
    }
    if (fnModified) {
      codeSection.functions[i] = repackFunction({
        locals: parsed.locals,
        instructions: newOps,
        size: parsed.size + 16,
      });
    }
  }
  if (patched === 0) {
    return binary;
  }
  return repackBinary({ sections, size: size + patched * 4 + 32 });
}

function parseBinary(binary) {
  const {
    eof,
    readBytes,
    readU8,
    readU32,
    readString,
    readArray,
    readU32Leb128,
    readExpression,
    readLimits,
    readCustom,
  } = createReader(binary);
  const magic = readU32();
  if (magic !== MagicNumber) {
    throw new Error(`Incorrect magic number: ${magic.toString(16)}`);
  }
  const version = readU32();
  if (version !== Version) {
    throw new Error(`Incorrect version: ${version}`);
  }
  const sections = [];
  while(!eof()) {
    sections.push(readSection());
  }
  const size = binary.byteLength;
  return { sections, size };

  function readSection() {
    const type = readU8();
    const len = readU32Leb128();
    switch(type) {
      case SectionType.Custom:
        const { name, data } = readCustom(len);
        return { type, name, data };
      case SectionType.Import: {
        const imports = readArray(() => {
          const module = readString();
          const name = readString();
          const type = readU8();
          switch (type) {
            case ObjectType.Function: {
              const index = readU32Leb128();
              return { module, name, type, index };
            }
            case ObjectType.Table: {
              const reftype = readU8();
              const limits = readLimits();
              return { module, name, type, reftype, limits };
            }
            case ObjectType.Memory: {
              const limits = readLimits();
              return { module, name, type, limits };
            }
            case ObjectType.Global: {
              const valtype = readU8();
              const mut = readU8();
              return { module, name, type, valtype, mut };
            }
            /* c8 ignore next 3 */
            default: {
              throw new Error(`Unknown object type: ${type}`);
            }
          }
        });
        return { type, imports };
      }
      case SectionType.Export: {
        const exports = readArray(() => {
          const name = readString();
          const type = readU8();
          const index = readU32Leb128();
          return { name, type, index };
        });
        return { type, exports };
      }
      case SectionType.Function: {
        const types = readArray(readU32Leb128);
        return { type, types };
      }
      case SectionType.Code: {
        const functions = readArray(() => {
          const len = readU32Leb128();
          return readBytes(len);
        });
        return { type, functions };
      }
      case SectionType.Element: {
        const segments = readArray(() => {
          const type = readU32Leb128();
          switch (type) {
            case 0: {
              const expr = readExpression();
              const indices = readArray(readU32Leb128);
              return { type, expr, indices };
            }
            case 1: {
              const kind = readU8();
              const indices = readArray(readU32Leb128);
              return { type, kind, indices };
            }
            case 2: {
              const tableidx = readU32Leb128();
              const expr = readExpression();
              const kind = readU8();
              const indices = readArray(readU32Leb128);
              return { type, tableidx, expr, kind, indices };
            }
            case 3: {
              const kind = readU8();
              const indices = readArray(readU32Leb128);
              return { type, kind, indices };
            }
            case 4: {
              const expr = readExpression();
              const entries = readArray(readExpression);
              return { type, expr, entries };
            }
            case 5: {
              const reftype = readU8();
              const entries = readArray(readExpression);
              return { type, reftype, entries };
            }
            case 6: {
              const tableidx = readU32Leb128();
              const expr = readExpression();
              const reftype = readU8();
              const entries = readArray(readExpression);
              return { type, tableidx, expr, reftype, entries };
            }
            case 7: {
              const reftype = readU8();
              const entries = readArray(readExpression);
              return { type, reftype, entries };
            }
          }
        });
        return { type, segments };
      }
      case SectionType.Start: {
        const funcidx = readU32Leb128();
        return { type, funcidx };
      }
      default: {
        const data = readBytes(len);
        return { type, data };
      }
    }
    /* c8 ignore next -- unreachable */
  }
}

function repackBinary(module) {
  const {
    finalize,
    writeBytes,
    writeU8,
    writeU32,
    writeLength,
    writeString,
    writeArray,
    writeU32Leb128,
    writeExpression,
    writeLimits,
    writeCustom,
  } = createWriter(module.size);
  writeU32(MagicNumber);
  writeU32(Version);
  for (const section of module.sections) {
    writeSection(section);
  }
  return finalize();

  function writeSection(section) {
    writeU8(section.type);
    writeLength(() => {
      switch(section.type) {
        case SectionType.Custom: {
          writeCustom(section);
        } break;
        case SectionType.Import: {
          writeArray(section.imports, (object) => {
            writeString(object.module);
            writeString(object.name);
            writeU8(object.type);
            switch (object.type) {
              case ObjectType.Function: {
                writeU32Leb128(object.index);
              } break;
              case ObjectType.Table: {
                writeU8(object.reftype);
                writeLimits(object.limits);
              } break;
              case ObjectType.Memory: {
                writeLimits(object.limits);
              } break;
              case ObjectType.Global: {
                writeU8(object.valtype);
                writeU8(object.mut);
              } break;
            }
          });
        } break;
        case SectionType.Export: {
          writeArray(section.exports, (object) => {
            writeString(object.name);
            writeU8(object.type);
            writeU32Leb128(object.index);
          });
        } break;
        case SectionType.Function: {
          writeArray(section.types, writeU32Leb128);
        } break;
        case SectionType.Code: {
          writeArray(section.functions, (code) => {
            writeU32Leb128(code.byteLength);
            writeBytes(code);
          });
        } break;
        case SectionType.Element: {
          writeArray(section.segments, (segment) => {
            writeU32Leb128(segment.type);
            switch (segment.type) {
              case 0: {
                writeExpression(segment.expr);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 1: {
                writeU8(segment.kind);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 2: {
                writeU32Leb128(segment.tableidx);
                writeExpression(segment.expr);
                writeU8(segment.kind);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 3: {
                writeU8(segment.kind);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 4: {
                writeExpression(segment.expr);
                writeArray(segment.entries, writeExpression);
              } break;
              case 5: {
                writeU8(segment.reftype);
                writeArray(segment.entries, writeExpression);
              } break;
              case 6: {
                writeU32Leb128(segment.tableidx);
                writeExpression(segment.expr);
                writeU8(segment.reftype);
                writeArray(segment.entries, writeExpression);
              } break;
              case 7: {
                writeU8(segment.reftype);
                writeArray(segment.entries, writeExpression);
              } break;
            }
          });
        } break;
        case SectionType.Start: {
          writeU32Leb128(section.funcidx);
        } break;
        default: {
          writeBytes(section.data);
        }
      }
    });
  }
}

function createReader(dv) {
  const decoder = new TextDecoder('utf-8', { ignoreBOM: true });
  let offset = 0;

  function eof() {
    return (offset >= dv.byteLength);
  }

  function skip(len) {
    offset += len;
  }

  function readBytes(len) {
    const bytes = new DataView(dv.buffer, dv.byteOffset + offset, len);
    offset += len;
    return bytes;
  }

  function readU8() {
    return dv.getUint8(offset++);
  }

  function readU32() {
    const value = dv.getUint32(offset, true);
    offset += 4;
    return value;
  }

  function readF64() {
    const value = dv.getFloat64(offset, true);
    offset += 8;
    return value;
  }

  function readString() {
    const len = readU32Leb128();
    const bytes = new Uint8Array(dv.buffer, dv.byteOffset + offset, len);
    offset += len;
    return decoder.decode(bytes);
  }

  function readArray(cb) {
    const len = readU32Leb128();
    const array = [];
    for (let i = 0; i < len; i++) {
      array.push(cb());
    }
    return array;
  }

  function readU32Leb128() {
    let value = 0;
    let shift = 0;
    while (true) {
      const byte = readU8();
      value |= (byte & 0x7f) << shift;
      shift += 7;
      if ((0x80 & byte) === 0) {
        if (value < 0) {
          value += 2 ** 32;
        }
        return value;
      }
    }
  }

  function readU64Leb128() {
    let value = 0n;
    let shift = 0n;
    while (true) {
      const byte = readU8();
      value |= BigInt(byte & 0x7f) << shift;
      shift += 7n;
      if ((0x80 & byte) === 0) {
        return (value > 0xFFFFFFFFn) ? value : Number(value);
      }
    }
  }

  function readI32Leb128() {
    let value = 0;
    let shift = 0;
    while (true) {
      const byte = dv.getUint8(offset++);
      value |= (byte & 0x7f) << shift;
      shift += 7;
      if ((0x80 & byte) === 0) {
        if (shift < 32 && (byte & 0x40) !== 0) {
          return value | (-1 << shift);
        }
        return value;
      }
    }
  }

  function readI64Leb128() {
    let value = 0n;
    let shift = 0n;
    while (true) {
      const byte = dv.getUint8(offset++);
      value |= BigInt(byte & 0x7f) << shift;
      shift += 7n;
      if ((0x80 & byte) === 0) {
        if ((byte & 0x40) !== 0) {
          return value | (~0n << shift);
        }
        return value;
      }
    }
  }

  function readExpression() {
    const start = offset;
    const { decodeNext } = createDecoder(self);
    let op;
    while (op = decodeNext()) {
      if (op.opcode === 0x0B) {
        break;
      }
    }
    const len = offset - start;
    return new DataView(dv.buffer, dv.byteOffset + start, len);
  }

  function readLimits() {
    const flags = readU8();
    const is64 = !!(flags & 0x04);
    const min = is64 ? Number(readU64Leb128()) : readU32Leb128();
    let max = undefined;
    let shared = undefined;
    if (flags & 0x01) {
      max = is64 ? Number(readU64Leb128()) : readU32Leb128();
    }
    if (flags & 0x02) {
      shared = true;
    }
    return { flags, min, max, shared, is64 };
  }

  function readCustom(len) {
    const offsetBefore = offset;
    const name = readString();
    const nameLen = offset - offsetBefore;
    const data = readBytes(len - nameLen);
    return { name, data };
  }

  const self = {
    eof,
    skip,
    readBytes,
    readU8,
    readU32,
    readF64,
    readString,
    readArray,
    readU32Leb128,
    readU64Leb128,
    readI32Leb128,
    readI64Leb128,
    readExpression,
    readLimits,
    readCustom,
  };
  return self;
}

function createWriter(maxSize) {
  const dv = new DataView(new ArrayBuffer(maxSize));
  const encoder = new TextEncoder();
  let offset = 0, lengthChecking = false;

  function finalize() {
    return new DataView(dv.buffer, 0, offset);
  }

  function writeBytes(bytes) {
    for (let i = 0; i < bytes.byteLength; i++) {
      writeU8(bytes.getUint8(i));
    }
  }

  function writeU8(value) {
    if (!lengthChecking) {
      dv.setUint8(offset, value);
    }
    offset++;
  }

  function writeU32(value) {
    if (!lengthChecking) {
      dv.setUint32(offset, value, true);
    }
    offset += 4;
  }

  function writeF64(value) {
    if (!lengthChecking) {
      dv.setFloat64(offset, value, true);
    }
    offset += 8;
  }

  function writeString(string) {
    const bytes = encoder.encode(string);
    writeU32Leb128(bytes.length);
    for (const byte of bytes) {
      writeU8(byte);
    }
  }

  function writeArray(values, cb) {
    writeU32Leb128(values.length);
    for (const value of values) {
      cb(value);
    }
  }

  function writeU32Leb128(value) {
    while (true) {
      const byte = value & 0x7f;
      value >>>= 7;
      if (value === 0) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeU64Leb128(value) {
    let v = (typeof value === 'bigint') ? value : BigInt(value);
    while (true) {
      const byte = Number(v & 0x7fn);
      v >>= 7n;
      if (v === 0n) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeI32Leb128(value) {
    while (true) {
      const byte = value & 0x7f;
      value >>= 7;
      if ((value === 0 && (byte & 0x40) === 0) || (value === -1 && (byte & 0x40) !== 0)) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeI64Leb128(value) {
    while (true) {
      const byte = Number(value & 0x7fn);
      value >>= 7n;
      if ((value === 0n && (byte & 0x40) === 0) || (value === -1n && (byte & 0x40) !== 0)) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeLength(cb) {
    const saved = offset;
    lengthChecking = true;
    cb();
    const length = offset - saved;
    offset = saved;
    lengthChecking = false;
    writeU32Leb128(length);
    cb();
  }

  function writeExpression(code) {
    writeBytes(code);
  }

  function writeLimits(limits) {
    const flags = limits.is64 ? (limits.flags | 0x04) : limits.flags;
    writeU8(flags);
    const writeVal = (flags & 0x04) ? writeU64Leb128 : writeU32Leb128;
    writeVal(limits.min);
    if (limits.max !== undefined) {
      writeVal(limits.max);
    }
  }

  function writeCustom({ name, data }) {
    writeString(name);
    writeBytes(data);
  }

  return {
    finalize,
    writeBytes,
    writeU8,
    writeU32,
    writeF64,
    writeString,
    writeArray,
    writeU32Leb128,
    writeU64Leb128,
    writeI32Leb128,
    writeI64Leb128,
    writeExpression,
    writeLimits,
    writeCustom,
    writeLength,
  };
}

function parseFunction(dv) {
  const reader = createReader(dv);
  const {
    readU8,
    readArray,
    readU32Leb128,
  } = reader;
  // read locals first
  const locals = readArray(() => {
    const number = readU32Leb128();
    const type = readU8();
    return { number, type };
  });
  // decode the expression
  const { decodeNext } = createDecoder(reader);
  const instructions = [];
  let op;
  while (op = decodeNext()) {
    instructions.push(op);
  }
  const size = dv.byteLength;
  return { locals, instructions, size };
}

function createDecoder(reader) {
  const {
    eof,
    readBytes,
    readU8,
    readArray,
    readU32Leb128,
    readU64Leb128,
    readI32Leb128,
    readI64Leb128,
    readU32,
    readF64,
  } = reader;
  const readOne = readU32Leb128;
  const readTwo = () => [ readOne(), readU64Leb128() ];
  const readMultiple = (count) => {
    const indices = [];
    for (let i = 0; i < count; i++) {
      indices.push(readOne());
    }
    return indices;
  };
  const operandReaders = {
    0x02: readI32Leb128,
    0x03: readI32Leb128,
    0x04: readI32Leb128,
    0x0C: readOne,
    0x0D: readOne,
    0x0E: () => [ readArray(readOne), readU32Leb128() ],

    0x10: readOne,
    0x11: readTwo,
    0x12: readOne,
    0x13: readTwo,
    0x14: readOne,
    0x15: readOne,

    0x1C: () => readArray(readU8),

    0x20: readOne,
    0x21: readOne,
    0x22: readOne,
    0x23: readOne,
    0x24: readOne,
    0x25: readOne,
    0x26: readOne,
    0x28: readTwo,
    0x29: readTwo,
    0x2A: readTwo,
    0x2B: readTwo,
    0x2C: readTwo,
    0x2D: readTwo,
    0x2E: readTwo,
    0x2F: readTwo,

    0x30: readTwo,
    0x31: readTwo,
    0x32: readTwo,
    0x33: readTwo,
    0x34: readTwo,
    0x35: readTwo,
    0x36: readTwo,
    0x37: readTwo,
    0x38: readTwo,
    0x39: readTwo,
    0x3A: readTwo,
    0x3B: readTwo,
    0x3C: readTwo,
    0x3D: readTwo,
    0x3E: readTwo,
    0x3F: readOne,

    0x40: readOne,
    0x41: readI32Leb128,
    0x42: readI64Leb128,
    0x43: readU32,  // avoid precision loss due to float-to-double conversion
    0x44: readF64,

    0xD0: readU8,
    0xD2: readOne,

    0xFC: () => {
      const op1 = readOne();
      switch (op1) {
        case 9:
        case 11:
        case 13:
        case 15:
        case 16:
        case 17:
          return [ op1, readOne() ];
        case 8:
        case 10:
        case 12:
        case 14:
          return [ op1, readOne(), readOne() ];
        default:
          return op1;
      }
    },
    0xFD: () => {
      const op1 = readOne();
      switch (op1) {
        case 21:
        case 22:
        case 23:
        case 24:
        case 25:
        case 26:
        case 27:
        case 28:
        case 29:
        case 30:
        case 31:
        case 32:
        case 33:
        case 34:
          return [ op1, readOne() ];
        case 0:
        case 1:
        case 2:
        case 3:
        case 5:
        case 6:
        case 7:
        case 8:
        case 9:
        case 10:
        case 11:
        case 92:
        case 93:
          return [ op1, readOne(), readU64Leb128() ];
        case 84:
        case 85:
        case 86:
        case 87:
        case 88:
        case 89:
        case 90:
        case 91:
          return [ op1, readOne(), readU64Leb128(), readOne() ];
        case 12:
          return [ op1, readBytes(16) ];
        case 13:
          return [ op1, ...readMultiple(16) ];
        default:
          return op1;
      }
    },
    0xFE: () => {
      const op1 = readOne();
      switch (op1) {
        /* c8 ignore next 2 */
        case 3:
          return [ op1, readU8() ];
        default:
          return [ op1, readOne(), readU64Leb128() ];
      }
    },
  };

  function decodeNext() {
    if (eof()) {
      return null;
    }
    const opcode = readU8();
    const f = operandReaders[opcode];
    const operand = f?.();
    return { opcode, operand };
  }

  return { decodeNext };
}

function repackFunction({ locals, instructions, size }) {
  const writer = createWriter(size);
  const {
    finalize,
    writeU8,
    writeArray,
    writeU32Leb128,
  } = writer;
  writeArray(locals, ({ number, type }) => {
    writeU32Leb128(number);
    writeU8(type);
  });
  const { encodeNext } = createEncoder(writer);
  for (const op of instructions) {
    encodeNext(op);
  }
  return finalize();
}

function createEncoder(writer) {
  const {
    writeBytes,
    writeU8,
    writeArray,
    writeU32Leb128,
    writeU64Leb128,
    writeI32Leb128,
    writeI64Leb128,
    writeU32,
    writeF64,
  } = writer;
  const writeOne = writeU32Leb128;
  const writeTwo = (op) => {
    writeOne(op[0]);
    writeU64Leb128(op[1]);
  };
  const writeMultiple = (indices) => {
    for (const index of indices) {
      writeU64Leb128(index);
    }
  };
  const operandWriters = {
    0x02: writeI32Leb128,
    0x03: writeI32Leb128,
    0x04: writeI32Leb128,
    0x0C: writeOne,
    0x0D: writeOne,
    0x0E: (op) => [ writeArray(op[0], writeOne), writeOne(op[1]) ],

    0x10: writeOne,
    0x11: writeTwo,
    0x12: writeOne,
    0x13: writeTwo,
    0x14: writeOne,
    0x15: writeOne,
    0x1C: (op) => writeArray(op, writeU8),

    0x20: writeOne,
    0x21: writeOne,
    0x22: writeOne,
    0x23: writeOne,
    0x24: writeOne,
    0x25: writeOne,
    0x26: writeOne,
    0x28: writeTwo,
    0x29: writeTwo,
    0x2A: writeTwo,
    0x2B: writeTwo,
    0x2C: writeTwo,
    0x2D: writeTwo,
    0x2E: writeTwo,
    0x2F: writeTwo,

    0x30: writeTwo,
    0x31: writeTwo,
    0x32: writeTwo,
    0x33: writeTwo,
    0x34: writeTwo,
    0x35: writeTwo,
    0x36: writeTwo,
    0x37: writeTwo,
    0x38: writeTwo,
    0x39: writeTwo,
    0x3A: writeTwo,
    0x3B: writeTwo,
    0x3C: writeTwo,
    0x3D: writeTwo,
    0x3E: writeTwo,
    0x3F: writeOne,

    0x40: writeOne,
    0x41: writeI32Leb128,
    0x42: writeI64Leb128,
    0x43: writeU32,   // avoid precision loss due to float-to-double conversion
    0x44: writeF64,

    0xD0: writeU8,
    0xD2: writeOne,

    0xFC: (op) => {
      if (op instanceof Array) {
        writeMultiple(op);
      } else {
        writeOne(op);
      }
    },
    0xFD: (op) => {
      if (op instanceof Array) {
        if (op[0] === 12) {
          writeOne(op[0]);
          writeBytes(op[1]);
        } else {
          writeMultiple(op);
        }
      } else {
        writeOne(op);
      }
    },
    0xFE: (op) => {
      writeMultiple(op);
    },
  };

  function encodeNext({ opcode, operand }) {
    writeU8(opcode);
    const f = operandWriters[opcode];
    f?.(operand);
  }

  return { encodeNext };
}

const execFileAsync = node_util.promisify(node_child_process.execFile);

let cachedWazigPathEnv;
let cachedHasWazig;

function hasWazigCommand() {
  const pathEnv = process.env.PATH ?? '';
  if (pathEnv === cachedWazigPathEnv && cachedHasWazig !== undefined) {
    return cachedHasWazig;
  }
  cachedWazigPathEnv = pathEnv;
  const binName = process.platform === 'win32' ? 'wazig.exe' : 'wazig';
  cachedHasWazig = pathEnv.split(node_path.delimiter).some(dir => {
    if (!dir) return false;
    try {
      node_fs.accessSync(node_path.join(dir, binName), node_fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
  return cachedHasWazig;
}

async function test(srcPath, options) {
  const { silent = false, extraArgs = [] } = options;
  const config = await createConfig(srcPath, '', { ...options, useRedirection: false, useBuildExe: false });
  const { zigPath, moduleBuildDir } = config;
  // create config file
  await createProject(config, moduleBuildDir);
  const cwd = moduleBuildDir;
  const stdio = (silent) ? 'pipe' : 'inherit';
  const child = node_child_process.spawn(zigPath, [ 'build', 'test', ...extraArgs ], { cwd, stdio, windowsHide: true });
  const output = [];
  child.stderr?.on('data', chunk => output.push(chunk));
  const code = await new Promise(resolve => child.on('close', resolve));
  const blob = new Blob(output);
  return { code, stderr: await blob.text() };
}

const witWasmModuleCache = new Map();

async function findWitZigarSrcDir() {
  const candidates = [
    node_url.fileURLToPath(new node_url.URL('../zig/wit-zigar/src', (typeof document === 'undefined' ? require('u' + 'rl').pathToFileURL(__filename).href : (_documentCurrentScript && _documentCurrentScript.tagName.toUpperCase() === 'SCRIPT' && _documentCurrentScript.src || new URL('index.cjs', document.baseURI).href)))),
    node_url.fileURLToPath(new node_url.URL('../../wit-zigar/src', (typeof document === 'undefined' ? require('u' + 'rl').pathToFileURL(__filename).href : (_documentCurrentScript && _documentCurrentScript.tagName.toUpperCase() === 'SCRIPT' && _documentCurrentScript.src || new URL('index.cjs', document.baseURI).href)))),
  ];
  for (const dir of candidates) {
    try {
      const info = await fs.stat(node_path.join(dir, 'main.zig'));
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

async function runWit(args = [], options = {}) {
  const {
    cwd: runCwd = process.cwd(),
    silent = false,
    buildDir = node_path.join(os.tmpdir(), 'zigar-build'),
    optimize = 'ReleaseSmall',
    recompile = false,
    zigPath: zigPathOption,
    useWazig: useWazigOption,
    onStart,
    onEnd,
  } = options;
  const witZigarSrcDir = await findWitZigarSrcDir();
  const zigPath = resolveWitZigPath(zigPathOption, useWazigOption);
  const witBuildDir = node_path.join(buildDir, 'wit-zigar-cli-' + sha1(`${witZigarSrcDir}:${zigPath}`).slice(0, 8));
  const wasmPath = node_path.join(witBuildDir, optimize, 'wit-zigar.wasm');
  const metaPath = node_path.join(witBuildDir, optimize, 'wit-zigar.meta.json');
  const pidPath = `${witBuildDir}.pid`;
  await acquireLock(pidPath);
  let wasmModule;
  try {
    const getWasmMTime = async () => {
      try {
        const stats = await fs.stat(wasmPath);
        return stats.mtimeMs;
      } catch {}
    };
    const getSavedMeta = async () => {
      try {
        return JSON.parse(await fs.readFile(metaPath, 'utf-8'));
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
      await stageDirectory(witZigarSrcDir, node_path.join(witBuildDir, 'src'), (name, isDir) => {
        if (isDir) {
          return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name);
        }
        return name.endsWith('.zig') || name.endsWith('.wit') || name.endsWith('.wasm') || name === 'NOTICE';
      });
      await createDirectory(node_path.join(witBuildDir, optimize));
      const sharedCacheDir = node_path.join(buildDir, `.zig-cache-${sha1(zigPath).slice(0, 8)}`);
      const localCacheDir = node_path.join(witBuildDir, '.zig-cache');
      await syncCacheDir(sharedCacheDir, localCacheDir);
      const zigArgs = [
        'build-exe',
        'src/main.zig',
        '--cache-dir', '.zig-cache',
        '--global-cache-dir', '.zig-cache',
        '-target', 'wasm32-wasi',
        '-O' + optimize,
        '-fsingle-threaded',
        `-femit-bin=${node_path.join(optimize, 'wit-zigar.wasm')}`,
      ];
      await runCompiler(zigPath, zigArgs, { cwd: witBuildDir, onStart, onEnd });
      await syncCacheDir(localCacheDir, sharedCacheDir);
      await fs.writeFile(metaPath, JSON.stringify({
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
      const wasmBytes = await fs.readFile(wasmPath);
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
  const hostRoot = node_path.parse(node_path.resolve(runCwd)).root || '/';
  const toWasiPath = (p) => {
    const resolved = node_path.resolve(runCwd, p);
    const rel = node_path.relative(hostRoot, resolved);
    if (node_path.isAbsolute(rel) || rel.startsWith('..')) {
      throw new Error(`Path lies outside WASI preopen root (${hostRoot}): ${p}`);
    }
    return rel.split(node_path.sep).join('/') || '.';
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

const tsWasmModuleCache = new Map();
const tsComponentBytesCache = new Map();

async function findTsZigarDir() {
  const candidates = [
    node_url.fileURLToPath(new node_url.URL('../zig/ts-zigar', (typeof document === 'undefined' ? require('u' + 'rl').pathToFileURL(__filename).href : (_documentCurrentScript && _documentCurrentScript.tagName.toUpperCase() === 'SCRIPT' && _documentCurrentScript.src || new URL('index.cjs', document.baseURI).href)))),
    node_url.fileURLToPath(new node_url.URL('../../ts-zigar', (typeof document === 'undefined' ? require('u' + 'rl').pathToFileURL(__filename).href : (_documentCurrentScript && _documentCurrentScript.tagName.toUpperCase() === 'SCRIPT' && _documentCurrentScript.src || new URL('index.cjs', document.baseURI).href)))),
  ];
  for (const dir of candidates) {
    try {
      const [ mainInfo, witInfo ] = await Promise.all([
        fs.stat(node_path.join(dir, 'src', 'main.zig')),
        fs.stat(node_path.join(dir, 'wit', 'typescript.wit')),
      ]);
      if (mainInfo.isFile() && witInfo.isFile()) {
        return dir;
      }
    } catch {}
  }
  throw new Error('Unable to locate ts-zigar directory (src/main.zig and wit/typescript.wit)');
}

async function isExistingFile(filePath) {
  if (!filePath) return false;
  try {
    const info = await fs.stat(filePath);
    return info.isFile();
  } catch {
    return false;
  }
}

async function hashPathForComponentKey(hash, targetPath, baseDir) {
  let info;
  try {
    info = await fs.stat(targetPath);
  } catch {
    return;
  }
  if (!info.isDirectory()) {
    const rel = node_path.relative(baseDir, targetPath).split(node_path.sep).join('/');
    hash.update(`file:${rel}\0`);
    hash.update(await fs.readFile(targetPath));
    hash.update('\0');
    return;
  }
  const entries = (await fs.readdir(targetPath, { withFileTypes: true }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const entry of entries) {
    await hashPathForComponentKey(hash, node_path.join(targetPath, entry.name), baseDir);
  }
}

async function computeTsComponentCacheKey(tsZigarDir) {
  const hash = node_crypto.createHash('sha256');
  await hashPathForComponentKey(hash, node_path.join(tsZigarDir, 'component', 'build-component.mjs'), tsZigarDir);
  await hashPathForComponentKey(hash, node_path.join(tsZigarDir, 'wit'), tsZigarDir);
  await hashPathForComponentKey(hash, node_path.join(tsZigarDir, 'component', 'adapter'), tsZigarDir);
  return hash.digest('hex').slice(0, 16);
}

async function resolveOrBuildTsComponentWasm({
  explicitComponentPath,
  componentOptionPath,
  tsZigarDir,
  buildDir,
}) {
  if (explicitComponentPath) {
    if (await isExistingFile(explicitComponentPath)) {
      return explicitComponentPath;
    }
    // Leave null so `ts-zigar` CLI emits its crisp missing-component diagnostic & non-zero exit code.
    return null;
  }
  if (componentOptionPath) {
    if (await isExistingFile(componentOptionPath)) {
      return componentOptionPath;
    }
    throw new Error(`TypeScript component WASM not found: ${componentOptionPath}`);
  }
  const envCandidates = [
    process.env.TS_ZIGAR_COMPONENT_PATH,
    process.env.TS_ZIGAR_COMPONENT_WASM,
  ];
  for (const envPath of envCandidates) {
    if (envPath && (await isExistingFile(envPath))) {
      return node_path.resolve(envPath);
    }
  }
  const localDistCandidates = [
    node_path.join(tsZigarDir, 'component', 'dist', 'typescript-compiler.component.wasm'),
    node_path.join(tsZigarDir, 'dist', 'typescript-compiler.component.wasm'),
  ];
  for (const cand of localDistCandidates) {
    if (await isExistingFile(cand)) {
      return cand;
    }
  }

  const componentKey = await computeTsComponentCacheKey(tsZigarDir);
  const cachedComponentPath = node_path.join(
    buildDir,
    `ts-zigar-component-${componentKey}`,
    'typescript-compiler.component.wasm',
  );
  if (await isExistingFile(cachedComponentPath)) {
    return cachedComponentPath;
  }

  const buildScript = node_path.join(tsZigarDir, 'component', 'build-component.mjs');
  if (await isExistingFile(buildScript)) {
    const lockPath = node_path.join(buildDir, `ts-zigar-component-${componentKey}.pid`);
    await acquireLock(lockPath);
    try {
      for (const cand of [ ...localDistCandidates, cachedComponentPath ]) {
        if (await isExistingFile(cand)) {
          return cand;
        }
      }
      const isInstalledPackage = tsZigarDir.split(/[/\\]/).includes('node_modules');
      let targetOut = isInstalledPackage
        ? cachedComponentPath
        : node_path.join(tsZigarDir, 'component', 'dist', 'typescript-compiler.component.wasm');
      try {
        await createDirectory(node_path.dirname(targetOut));
      } catch {
        targetOut = cachedComponentPath;
        await createDirectory(node_path.dirname(targetOut));
      }
      const buildEnv = isInstalledPackage
        ? {
            ...process.env,
            TS_ZIGAR_CACHE_DIR: process.env.TS_ZIGAR_CACHE_DIR || node_path.join(buildDir, 'ts-zigar'),
          }
        : process.env;
      await execFileAsync(process.execPath, [ buildScript, '-o', targetOut ], {
        cwd: tsZigarDir,
        env: buildEnv,
      });
      if (await isExistingFile(targetOut)) {
        return targetOut;
      }
    } finally {
      await releaseLock(lockPath);
    }
  }

  throw new Error(
    'Unable to locate or build typescript-compiler.component.wasm (set TS_ZIGAR_COMPONENT_PATH or pass --component <path>)',
  );
}

async function loadCachedComponentBytes(wasmFilePath) {
  const info = await fs.stat(wasmFilePath);
  const cached = tsComponentBytesCache.get(wasmFilePath);
  if (cached && cached.mtimeMs === info.mtimeMs && cached.size === info.size) {
    return cached.bytes;
  }
  const buf = await fs.readFile(wasmFilePath);
  const bytes = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  tsComponentBytesCache.set(wasmFilePath, {
    mtimeMs: info.mtimeMs,
    size: info.size,
    bytes,
  });
  return bytes;
}

async function runTs(args = [], options = {}) {
  const {
    cwd: runCwd = process.cwd(),
    silent = false,
    buildDir = process.env.ZIGAR_CACHE_DIR || node_path.join(os.tmpdir(), 'zigar-build'),
    optimize = 'ReleaseSmall',
    recompile = false,
    zigPath: zigPathOption,
    useWazig: useWazigOption,
    componentPath: componentOptionPath,
    onStart,
    onEnd,
  } = options;
  const [ witZigarSrcDir, tsZigarDir ] = await Promise.all([
    findWitZigarSrcDir(),
    findTsZigarDir(),
  ]);
  const tsSrcDir = node_path.join(tsZigarDir, 'src');
  const tsWitPath = node_path.join(tsZigarDir, 'wit', 'typescript.wit');
  const zigPath = resolveWitZigPath(zigPathOption, useWazigOption);
  const tsBuildDir = node_path.join(
    buildDir,
    'ts-zigar-cli-' + sha1(`${tsZigarDir}:${witZigarSrcDir}:${zigPath}`).slice(0, 8),
  );
  const wasmPath = node_path.join(tsBuildDir, optimize, 'ts-zigar.wasm');
  const metaPath = node_path.join(tsBuildDir, optimize, 'ts-zigar.meta.json');
  const pidPath = `${tsBuildDir}.pid`;

  await acquireLock(pidPath);
  let wasmModule;
  try {
    const getWasmMTime = async () => {
      try {
        const stats = await fs.stat(wasmPath);
        return stats.mtimeMs;
      } catch {}
    };
    const getSavedMeta = async () => {
      try {
        return JSON.parse(await fs.readFile(metaPath, 'utf-8'));
      } catch {
        return null;
      }
    };
    const [ wasmMTimeBefore, tsSrcStats, witFileStats, witZigarStats, savedMeta ] = await Promise.all([
      getWasmMTime(),
      getDirectoryStats(tsSrcDir),
      fs.stat(tsWitPath),
      getDirectoryStats(witZigarSrcDir),
      getSavedMeta(),
    ]);
    const latestInputMtime = Math.max(
      tsSrcStats.mtimeMs,
      witFileStats.mtimeMs,
      witZigarStats.mtimeMs,
    );
    const metaMatches = Boolean(
      savedMeta &&
      savedMeta.tsSize === tsSrcStats.size &&
      savedMeta.tsMtimeMs === tsSrcStats.mtimeMs &&
      savedMeta.witSize === witFileStats.size &&
      savedMeta.witMtimeMs === witFileStats.mtimeMs &&
      savedMeta.witZigarSize === witZigarStats.size &&
      savedMeta.witZigarMtimeMs === witZigarStats.mtimeMs &&
      savedMeta.zigPath === zigPath
    );
    if (!wasmMTimeBefore || !metaMatches || wasmMTimeBefore < latestInputMtime || recompile === true) {
      await stageDirectory(tsSrcDir, node_path.join(tsBuildDir, 'src'), (name, isDir) => {
        if (isDir) {
          return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name);
        }
        return name.endsWith('.zig');
      });
      await stageDirectory(witZigarSrcDir, node_path.join(tsBuildDir, 'wit-zigar'), (name, isDir) => {
        if (isDir) {
          return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name);
        }
        return name.endsWith('.zig');
      });
      await createDirectory(node_path.join(tsBuildDir, 'generated'));
      await createDirectory(node_path.join(tsBuildDir, optimize));

      const gen32Path = node_path.join(tsBuildDir, 'generated', 'generated_ts_wasm32.zig');
      const gen64Path = node_path.join(tsBuildDir, 'generated', 'generated_ts_wasm64.zig');
      const witRes32 = await runWit([ tsWitPath, '-o', gen32Path ], {
        cwd: tsBuildDir,
        silent: true,
        buildDir,
        optimize,
        zigPath,
      });
      if (witRes32.code !== 0) {
        throw new Error(`wit-zigar failed generating wasm32 TS bindings:\n${witRes32.stderr}`);
      }
      const witRes64 = await runWit([ tsWitPath, '--wasm64', '-o', gen64Path ], {
        cwd: tsBuildDir,
        silent: true,
        buildDir,
        optimize,
        zigPath,
      });
      if (witRes64.code !== 0) {
        throw new Error(`wit-zigar failed generating wasm64 TS bindings:\n${witRes64.stderr}`);
      }

      const buildOptionsSource = [
        'pub const default_component_path: []const u8 = "";',
        'pub const build_component_script_path: []const u8 = "";',
        'pub const default_node_exe: []const u8 = "node";',
        '',
      ].join('\n');
      await fs.writeFile(node_path.join(tsBuildDir, 'generated', 'build_options.zig'), buildOptionsSource, 'utf-8');

      const sharedCacheDir = node_path.join(buildDir, `.zig-cache-${sha1(zigPath).slice(0, 8)}`);
      const localCacheDir = node_path.join(tsBuildDir, '.zig-cache');
      await syncCacheDir(sharedCacheDir, localCacheDir);
      const zigArgs = [
        'build-exe',
        '--cache-dir', '.zig-cache',
        '--global-cache-dir', '.zig-cache',
        '-target', 'wasm32-wasi',
        '-O' + optimize,
        '-fsingle-threaded',
        '--dep', 'ts_zigar',
        '--dep', 'build_options',
        '-Mroot=src/main.zig',
        '--dep', 'wit_zigar',
        '--dep', 'generated_ts_wasm32',
        '--dep', 'generated_ts_wasm64',
        '-Mts_zigar=src/root.zig',
        '-Mbuild_options=generated/build_options.zig',
        '-Mwit_zigar=wit-zigar/root.zig',
        '-Mgenerated_ts_wasm32=generated/generated_ts_wasm32.zig',
        '-Mgenerated_ts_wasm64=generated/generated_ts_wasm64.zig',
        `-femit-bin=${node_path.join(optimize, 'ts-zigar.wasm')}`,
      ];
      await runCompiler(zigPath, zigArgs, { cwd: tsBuildDir, onStart, onEnd });
      await syncCacheDir(localCacheDir, sharedCacheDir);
      await fs.writeFile(metaPath, JSON.stringify({
        tsSize: tsSrcStats.size,
        tsMtimeMs: tsSrcStats.mtimeMs,
        witSize: witFileStats.size,
        witMtimeMs: witFileStats.mtimeMs,
        witZigarSize: witZigarStats.size,
        witZigarMtimeMs: witZigarStats.mtimeMs,
        zigPath,
      }));
    }
    const wasmMTime = await getWasmMTime();
    const cached = tsWasmModuleCache.get(wasmPath);
    if (
      cached &&
      !recompile &&
      cached.mtimeMs === wasmMTime &&
      cached.tsMtimeMs === tsSrcStats.mtimeMs &&
      cached.tsSize === tsSrcStats.size
    ) {
      wasmModule = cached.module;
    } else {
      const wasmBytes = await fs.readFile(wasmPath);
      wasmModule = await WebAssembly.compile(wasmBytes);
      tsWasmModuleCache.set(wasmPath, {
        mtimeMs: wasmMTime,
        tsMtimeMs: tsSrcStats.mtimeMs,
        tsSize: tsSrcStats.size,
        module: wasmModule,
      });
    }
  } finally {
    await releaseLock(pidPath);
  }

  const hostRoot = node_path.parse(node_path.resolve(runCwd)).root || '/';
  const toWasiPath = (p) => {
    if (p === '') return '';
    const resolved = node_path.resolve(runCwd, p);
    const rel = node_path.relative(hostRoot, resolved);
    if (node_path.isAbsolute(rel) || rel.startsWith('..')) {
      throw new Error(`Path lies outside WASI preopen root (${hostRoot}): ${p}`);
    }
    return rel.split(node_path.sep).join('/') || '.';
  };

  const normalizedArgs = [];
  let hasHelpOrVersion = false;
  let hasTypes = false;
  let hasOutDir = false;
  let explicitComponentPath = null;

  for (let i = 0; i < args.length; i++) {
    const arg = String(args[i]);
    if (arg === '-h' || arg === '--help' || arg === '-v' || arg === '--version') {
      hasHelpOrVersion = true;
      normalizedArgs.push(arg);
    } else if (arg === '-t' || arg === '--types') {
      normalizedArgs.push(arg);
      if (i + 1 < args.length) {
        const val = String(args[++i]);
        if (val.length > 0) hasTypes = true;
        normalizedArgs.push(toWasiPath(val));
      }
    } else if (arg.startsWith('-t=') || arg.startsWith('--types=')) {
      const eq = arg.indexOf('=');
      const prefix = arg.slice(0, eq + 1);
      const val = arg.slice(eq + 1);
      if (val.length > 0) hasTypes = true;
      normalizedArgs.push(prefix + toWasiPath(val));
    } else if (arg === '-d' || arg === '--out-dir') {
      normalizedArgs.push(arg);
      if (i + 1 < args.length) {
        const val = String(args[++i]);
        if (val.length > 0) hasOutDir = true;
        normalizedArgs.push(toWasiPath(val));
      }
    } else if (arg.startsWith('-d=') || arg.startsWith('--out-dir=')) {
      const eq = arg.indexOf('=');
      const prefix = arg.slice(0, eq + 1);
      const val = arg.slice(eq + 1);
      if (val.length > 0) hasOutDir = true;
      normalizedArgs.push(prefix + toWasiPath(val));
    } else if (arg === '--component') {
      normalizedArgs.push(arg);
      if (i + 1 < args.length) {
        const val = String(args[++i]);
        if (val.length > 0) {
          explicitComponentPath = node_path.resolve(runCwd, val);
        }
        normalizedArgs.push(toWasiPath(val));
      }
    } else if (arg.startsWith('--component=')) {
      const eq = arg.indexOf('=');
      const prefix = arg.slice(0, eq + 1);
      const val = arg.slice(eq + 1);
      if (val.length > 0) {
        explicitComponentPath = node_path.resolve(runCwd, val);
      }
      normalizedArgs.push(prefix + toWasiPath(val));
    } else if (arg === '-m' || arg === '--module' || arg === '-s' || arg === '--substitute') {
      normalizedArgs.push(arg);
      if (i + 1 < args.length) {
        normalizedArgs.push(String(args[++i]));
      }
    } else {
      normalizedArgs.push(arg);
    }
  }

  let componentBytes = null;
  if (!hasHelpOrVersion && hasTypes && hasOutDir) {
    const resolvedCompPath = await resolveOrBuildTsComponentWasm({
      explicitComponentPath,
      componentOptionPath: componentOptionPath ? node_path.resolve(runCwd, componentOptionPath) : null,
      tsZigarDir,
      buildDir,
    });
    if (resolvedCompPath) {
      componentBytes = await loadCachedComponentBytes(resolvedCompPath);
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
      args: [ 'ts-zigar', ...normalizedArgs ],
      env: process.env,
      preopens: { '/': hostRoot },
      returnOnExit: true,
    });
  } finally {
    process.emitWarning = origEmitWarning;
  }

  const rawImports = wrapWasiImportsUnsigned(
    typeof wasi.getImportObject === 'function'
      ? wasi.getImportObject()
      : { wasi_snapshot_preview1: wasi.wasiImport },
  );
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
      const uIovsPtr = iovsPtr >>> 0;
      const uNwrittenPtr = nwrittenPtr >>> 0;
      const { buffer } = instance.exports.memory;
      const view = new DataView(buffer);
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(uIovsPtr + i * 8, true);
        const len = view.getUint32(uIovsPtr + i * 8 + 4, true);
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
      view.setUint32(uNwrittenPtr, total, true);
      return 0;
    }
    return origFdWrite(fd, iovsPtr, iovsLen, nwrittenPtr);
  };

  let componentHost = null;
  let realHostImports = null;
  const ensureHostImports = () => {
    if (!realHostImports) {
      if (!componentBytes) {
        throw new Error('TypeScript 7.1 component WASM is not loaded');
      }
      componentHost = instantiateComponentHost(componentBytes, { register: false });
      realHostImports = componentHost.createWasmImports(() => instance.exports.memory)['zigar:component-host'];
    }
    return realHostImports;
  };
  const hostBridge = {};
  for (const imp of WebAssembly.Module.imports(wasmModule)) {
    if (imp.module === 'zigar:component-host' && imp.kind === 'function') {
      hostBridge[imp.name] = (...callArgs) => ensureHostImports()[imp.name](...callArgs);
    }
  }
  importObject['zigar:component-host'] = hostBridge;

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
  } finally {
    try {
      componentHost?.dispose();
    } catch {}
  }
  const stdout = Buffer.concat(stdoutChunks).toString('utf-8');
  const stderr = Buffer.concat(stderrChunks).toString('utf-8');
  return { code, stdout, stderr };
}

async function compile(srcPath, modPath, options) {
  const srcInfo = (srcPath) ? await fs.stat(srcPath) : null;
  if (srcInfo?.isDirectory()) {
    srcPath = node_path.join(srcPath, '?');
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
        const stats = await fs.stat(outputPath);
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
          ? node_path.join(config.buildDir, `.zig-cache-${sha1(config.zigPath).slice(0, 8)}`)
          : null;
        const localCacheDir = node_path.join(moduleBuildDir, '.zig-cache');
        if (sharedCacheDir) {
          await syncCacheDir(sharedCacheDir, localCacheDir);
        }
        if (config.useBuildExe && config.translateCArgs) {
          const cCode = await runCompiler(zigPath, config.translateCArgs, { cwd: moduleBuildDir });
          await fs.writeFile(node_path.join(moduleBuildDir, 'c.zig'), cCode);
        }
        // then run the compiler
        await runCompiler(zigPath, zigArgs, { cwd: moduleBuildDir, onStart, onEnd });
        if (sharedCacheDir) {
          await syncCacheDir(localCacheDir, sharedCacheDir);
        }
        const emittedWasmPath = config.useBuildExe
          ? node_path.join(moduleBuildDir, config.relOutputPath)
          : outputPath;
        if (config.arch === 'wasm64' && config.multithreaded) {
          const rawBytes = await fs.readFile(emittedWasmPath);
          const rawDV = new DataView(rawBytes.buffer, rawBytes.byteOffset, rawBytes.byteLength);
          const fixedDV = fixWasm64TlsGlobals(rawDV);
          if (fixedDV !== rawDV) {
            await fs.writeFile(emittedWasmPath, new Uint8Array(fixedDV.buffer, fixedDV.byteOffset, fixedDV.byteLength));
          }
        }
        if (config.useBuildExe) {
          if (emittedWasmPath !== outputPath) {
            await createDirectory(node_path.dirname(outputPath));
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

async function runCompiler(path, args, options) {
  const {
    cwd,
    onStart,
    onEnd,
  } = options;
  const unlock = await getLock();
  try {
    onStart?.();
    const isWazig = node_path.basename(path).startsWith('wazig');
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
      if (!env.GHR_TOOL_DIR && node_path.isAbsolute(path)) {
        env.GHR_TOOL_DIR = node_path.resolve(node_path.dirname(path), '..');
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
        const logPath = node_path.join(cwd, 'log');
        node_fs.writeFileSync(logPath, err.stderr);
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

function formatProjectConfig(config) {
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

function formatOptionsZig(config) {
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
  const entries = await fs.readdir(srcDir, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = node_path.join(srcDir, entry.name);
    const dstPath = node_path.join(dstDir, entry.name);
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
    entries = await fs.readdir(srcDir, { withFileTypes: true });
  } catch {
    return;
  }
  await createDirectory(dstDir);
  for (const entry of entries) {
    if (entry.name === 'tmp') continue;
    const srcPath = node_path.join(srcDir, entry.name);
    const dstPath = node_path.join(dstDir, entry.name);
    if (entry.isDirectory()) {
      await syncCacheDir(srcPath, dstPath, entry.name === 'h');
    } else if (entry.isFile()) {
      try {
        await fs.link(srcPath, dstPath);
      } catch (err) {
        if (err.code === 'EEXIST') {
          if (isManifestDir) {
            try {
              const [srcStat, dstStat] = await Promise.all([fs.stat(srcPath), fs.stat(dstPath)]);
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

async function createProject(config, dir = config.moduleBuildDir) {
  await createDirectory(dir);
  const content = formatProjectConfig(config);
  const cfgFilePath = node_path.join(dir, 'build.cfg.zig');
  await fs.writeFile(cfgFilePath, content);
  if (config.useBuildExe) {
    const optionsFilePath = node_path.join(dir, 'options.zig');
    await fs.writeFile(optionsFilePath, formatOptionsZig(config));
    await stageDirectory(config.zigarSrcPath, node_path.join(dir, 'zig'), (name, isDir) => {
      if (isDir) {
        return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name);
      }
      if (name === 'build.zig' || name === 'build.extra.zig' || name === 'options.zig') {
        return false;
      }
      return name.endsWith('.zig') || name.endsWith('.h');
    });
    await stageDirectory(config.moduleDir, node_path.join(dir, 'src'), (name, isDir) => {
      if (isDir) {
        return !['.zig-cache', 'zig-cache', 'zig-out', 'node_modules'].includes(name) && !name.endsWith('.zigar');
      }
      return name.endsWith('.zig') || name.endsWith('.h') || name.endsWith('.c');
    });
    await createDirectory(node_path.join(dir, node_path.dirname(config.relOutputPath)));
  } else {
    const buildFilePath = node_path.join(dir, 'build.zig');
    await copyFile(buildFilePath, config.buildFilePath);
    const extraFilePath = node_path.join(dir, 'build.extra.zig');
    if (config.extraFilePath) {
      await copyFile(extraFilePath, config.extraFilePath);
    } else {
      await fs.writeFile(extraFilePath, '');
    }
    if (config.packageConfigPath) {
      const packageConfigPath = node_path.join(dir, 'build.zig.zon');
      await copyZonFile(config.packageConfigPath, packageConfigPath);
    }
  }
}

const cwd = process.cwd();

function getCachePath(options) {
  const {
    cacheDir = node_path.join(cwd, '.zigar-cache'),
  } = options;
  return cacheDir;
}

function getModuleCachePath(srcPath, options = {}) {
  const {
    optimize,
    memory64 = false,
    arch,
  } = options;
  const isWasm64 = Boolean(memory64 || arch === 'wasm64');
  const src = node_path.parse(srcPath);
  const baseFolder = node_path.basename(src.dir).slice(0, 16).trim() + '-' + sha1(src.dir).slice(0, 8);
  const folder = isWasm64 ? `${baseFolder}-wasm64` : baseFolder;
  const cacheDir = getCachePath(options);
  return node_path.join(cacheDir, folder, optimize, `${src.name}.zigar`);
}

async function findModuleFile(moduleDir, fileName) {
  try {
    // add custom build file if one is found
    const path = moduleDir + fileName;
    await fs.stat(path);
    return path;
  } catch (err) {
  }
}

async function createConfig(srcPath, modPath, options = {}) {
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
    buildDir = node_path.join(os.tmpdir(), 'zigar-build'),
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
  const src = node_path.parse(srcPath ?? '');
  const mod = node_path.parse(modPath ?? '');
  const moduleName = mod.name || src.name;
  const modulePath = (src.name !== '?') ? srcPath : undefined;
  const moduleDir = src.dir + node_path.sep;
  const modulePrefix = node_path.basename(moduleName).slice(0, 16);
  const moduleHash = sha1(moduleDir).slice(0, 8);
  const moduleBuildDir = node_path.join(buildDir, `${modulePrefix}-${moduleHash}${arch === 'wasm64' ? '-wasm64' : ''}`);
  const relOutputPath = node_path.join(optimize, arch === 'wasm64' ? `${src.name}.wasm64.wasm` : `${src.name}.wasm`);
  const outputPath = (() => {
    if (!modPath && isWASM) {
      // save output in build folder
      return node_path.join(moduleBuildDir, relOutputPath);
    } else {
      const ext = getLibraryExt(platform);
      return node_path.join(modPath, `${platform}.${arch}.${ext}`);
    }
  })();
  let pdbPath;
  if (platform === 'win32') {
    pdbPath = node_path.join(node_path.dirname(outputPath), `${platform}.${arch}.pdb`);
  }
  const zigarSrcPath = node_url.fileURLToPath(new node_url.URL('../zig/', (typeof document === 'undefined' ? require('u' + 'rl').pathToFileURL(__filename).href : (_documentCurrentScript && _documentCurrentScript.tagName.toUpperCase() === 'SCRIPT' && _documentCurrentScript.src || new URL('index.cjs', document.baseURI).href))));
  let buildFilePath = node_path.join(zigarSrcPath, `build.zig`);
  let hasCustomBuildFile = false;
  if (!ignoreBuildFile) {
    // use custom build file if one is found
    const customBuildFilePath = await findModuleFile(moduleDir, 'build.zig');
    if (customBuildFilePath) {
      const code = await fs.readFile(customBuildFilePath, 'utf-8');
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
    (zigPathOption && node_path.basename(zigPathOption).startsWith('wazig')) ||
    (!zigPathOption && process.env.ZIG_PATH && node_path.basename(process.env.ZIG_PATH).startsWith('wazig'))
  );
  const useBuildExe = Boolean(
    modulePath && (useBuildExeOption ?? (isWASM && !hasCustomBuildFile && !extraFilePath && !packageConfigPath && !zigArgsStr.trim() && (useLLVM !== true || isWazigPath)))
  );
  let useWazig;
  let zigPath;
  if (zigPathOption !== undefined) {
    zigPath = zigPathOption;
    useWazig = Boolean(useWazigOption ?? node_path.basename(zigPath).startsWith('wazig'));
  } else if (useWazigOption !== undefined) {
    useWazig = Boolean(useWazigOption);
    zigPath = useWazig ? (process.env.WA_ZIG_PATH || 'wazig') : (process.env.ZIG_PATH || 'zig');
  } else if (process.env.ZIG_PATH) {
    zigPath = process.env.ZIG_PATH;
    useWazig = node_path.basename(zigPath).startsWith('wazig');
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
      `-Mroot=${node_path.join('zig', 'stub.zig')}`,
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
      `-Mmodule=${node_path.join('src', node_path.basename(modulePath))}`,
      '-Moptions.zig=options.zig',
      '-O' + optimize,
      '-target', target,
      '-mcpu', cpu,
      `-Mzigar=${node_path.join('zig', 'zigar.zig')}`,
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
        node_path.join('src', node_path.basename(cHeaderPath)),
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
    dirPath = node_path.join(buildPath, '.zig-cache', 'h');
    names = await fs.readdir(dirPath);
    /* c8 ignore next 8 */
  } catch (err) {
    try {
      dirPath = node_path.join(buildPath, 'zig-cache', 'h');
      names = await fs.readdir(dirPath);
    } catch (err) {
      names = [];
    }
  }
  return names.filter(n => /^\w{32}$/.test(n)).map(n => node_path.join(dirPath, n));
}

async function findSourcePaths(buildPath, config) {
  const realBuildPath = await fs.realpath(buildPath);
  const manifestPaths = await getManifestLists(realBuildPath);
  const involved = {};
  for (const manifestPath of manifestPaths) {
    try {
      const data = await fs.readFile(manifestPath);
      let offset = 41;
      while (offset < data.length) {
        const si = offset;
        while (data[offset] !== 0 && offset < data.length) offset++;
        const ei = offset;
        const pathBytes = data.subarray(si, ei);
        let srcPath = pathBytes.toString('utf-8');
        if (config?.useBuildExe) {
          let rel = srcPath;
          if (rel.startsWith(realBuildPath + node_path.sep)) {
            rel = rel.slice(realBuildPath.length + 1);
          } else if (rel.startsWith('./') || rel.startsWith('.\\')) {
            rel = rel.slice(2);
          }
          if (rel.startsWith('src/') || rel.startsWith('src\\')) {
            srcPath = config.moduleDir ? node_path.join(config.moduleDir, rel.slice(4)) : srcPath;
          } else if (rel.startsWith('zig/') || rel.startsWith('zig\\')) {
            srcPath = config.zigarSrcPath ? node_path.join(config.zigarSrcPath, rel.slice(4)) : srcPath;
          }
        }
        if(node_path.isAbsolute(srcPath) && !srcPath.startsWith(realBuildPath) && !srcPath.includes('/.cache/zig/')) {
          try {
            await fs.stat(srcPath);
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
        await fs.stat(config.cHeaderPath);
        involved[config.cHeaderPath] = true;
      } catch {}
    }
    const queue = [
      config.modulePath,
      config.zigarSrcPath ? node_path.join(config.zigarSrcPath, 'stub.zig') : null,
      config.zigarSrcPath ? node_path.join(config.zigarSrcPath, 'zigar.zig') : null,
    ].filter(Boolean);
    const visited = new Set();
    while (queue.length > 0) {
      const filePath = queue.shift();
      if (visited.has(filePath)) continue;
      visited.add(filePath);
      try {
        await fs.stat(filePath);
        involved[filePath] = true;
        if (filePath.endsWith('.zig')) {
          const content = await fs.readFile(filePath, 'utf-8');
          const dir = node_path.dirname(filePath);
          const regex = /@(?:import|embedFile)\(\s*"([^"]+)"\s*\)/g;
          let match;
          while ((match = regex.exec(content)) !== null) {
            const spec = match[1];
            if (spec === 'options.zig') continue;
            if (spec.endsWith('.zig') || spec.startsWith('.') || spec.includes('/')) {
              const resolved = node_path.resolve(dir, spec);
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
    const names = await fs.readdir(buildDir);
    const list = [];
    let total = 0;
    for (const name of names) {
      const path = node_path.join(buildDir, name);
      const info = await fs.stat(path);
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

const optionsForCompile = {
  optimize: {
    type: 'string',
    enum: [ 'Debug', 'ReleaseSmall', 'ReleaseFast', 'ReleaseSafe' ],
    title: 'Zig optimization mode',
  },
  omitFunctions: {
    type: 'boolean',
    title: 'Omit all Zig functions',
  },
  omitVariables: {
    type: 'boolean',
    title: 'Omit all variables',
  },
  omitExports: {
    type: 'boolean',
    title: 'Omit export statements',
  },
  evalBranchQuota: {
    type: 'number',
    title: 'Value provided to @setEvalBranchQuota() during export',
  },
  useLibc: {
    type: 'boolean',
    title: 'Link in C standard library',
  },
  useLLVM: {
    type: 'boolean',
    title: 'Use LLVM as compiler backend',
  },
  useWazig: {
    type: 'boolean',
    title: 'Use wazig WebAssembly Zig compiler',
  },
  useRedirection: {
    type: 'boolean',
    title: 'Redirect IO operations to JavaScript handlers',
  },
  topLevelAwait: {
    type: 'boolean',
    title: 'Use top-level await to load WASM file',
  },
  multithreaded: {
    type: 'boolean',
    title: 'Enable multithreading',
  },
  memory64: {
    type: 'boolean',
    title: 'Compile for 64-bit WebAssembly (wasm64)',
  },
  buildDir: {
    type: 'string',
    title: 'Root directory where temporary build directories are placed',
  },
  cacheDir: {
    type: 'string',
    title: 'Directory where compiled library files are placed',
  },
  zigPath: {
    type: 'string',
    title: 'Zig command used to build libraries',
  },
  zigArgs: {
    type: 'string',
    title: 'Addition command-line passed to the Zig compiler',
  },
  modules: {
    type: 'object',
    title: 'Information concerning individual modules, including source file and loader',
  },
  sourceFiles: {
    type: 'object',
    title: 'Map of modules to source files/directories (legacy)',
  },
  quiet: {
    type: 'boolean',
    title: 'Disable compilation indicator',
  },
  recompile: {
    type: 'boolean',
    title: 'Recompile module when source file have been changed',
  },
  clean: {
    type: 'boolean',
    title: 'Remove temporary build directory after compilation finishes',
  },
  targets: {
    type: 'object',
    title: 'List of cross-compilation targets',
  },
  ignoreBuildFile: {
    type: 'boolean',
    title: 'Ignore build.zig present alongside source files',
  },
};

const optionsForTranspile = {
  nodeCompat: {
    type: 'boolean',
    title: 'Produce code compatible with Node.js',
  },
  embedWASM: {
    type: 'boolean',
    title: 'Embed WASM file in JavaScript source code',
  },
  stripWASM: {
    type: 'boolean',
    title: 'Remove unnecessary code from WASM file',
  },
  stackSize: {
    type: 'number',
    title: 'Size of the call stack in bytes',
  },
  maxMemory: {
    type: 'number',
    title: 'Maximum amount of shared memory in bytes',
  },
  keepNames: {
    type: 'boolean',
    title: 'Keep names of function in WASM binary when stripping',
  },
  usePthreadEmulation: {
    type: 'boolean',
    title: 'Provide emulated pthread functions',
  },
  useJSPI: {
    anyOf: [
      { type: 'boolean' },
      { type: 'string', enum: [ 'all', 'auto' ] },
      { type: 'array', items: { type: 'string' } },
    ],
    title: 'Use JavaScript Promise Integration (JSPI)',
  },
  continuationStackSize: {
    type: 'number',
    title: 'Size of each JSPI continuation stack in bytes',
  },
  memory64: {
    type: 'boolean',
    title: 'Compile for 64-bit WebAssembly (wasm64)',
  },
  useResizableBuffer: {
    type: 'boolean',
    title: 'Use resizable ArrayBuffer for WebAssembly memory',
  },
  moduleFormat: {
    type: 'string',
    enum: [ 'esm', 'cjs' ],
    title: 'Output JavaScript module format',
  },
  dynamicJsImports: {
    type: 'boolean',
    title: 'Load referenced JS modules dynamically instead of emitting static imports',
  },
};

const allOptions = {
  ...optionsForCompile,
  ...optionsForTranspile,
};

function extractOptions(searchParams, availableOptions) {
  const options = {};
  const names = Object.keys(availableOptions);
  for (const [ name, string ] of searchParams) {
    const key = getCamelCase(name, names);
    const option = availableOptions[key];
    if (!option) {
      throw new UnknownOption(name);
    }
    if (key === 'optimize') {
      options[key] = getCamelCase(string, [ 'Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall' ]);
    } else if (key === 'useJSPI') {
      if (string === '1' || string === 'true') {
        options[key] = true;
      } else if (string === '0' || string === 'false' || string === '') {
        options[key] = false;
      } else if (string === 'all' || string === 'auto') {
        options[key] = string;
      } else {
        options[key] = string.split(',').map(s => s.trim()).filter(Boolean);
      }
    } else {
      switch (option.type) {
        case 'boolean':
          options[key] = (string === 'true') ? true : (string === 'false') ? false : !!parseInt(string);
          break;
        case 'number':
          options[key] = parseInt(string);
          break;
        default:
          options[key] = string;
      }
    }
  }
  return options;
}

function getCamelCase(name, names) {
  for (const nameCC of names) {
    const nameSC = nameCC.replace(/([a-z])([A-Z]|\d+)/g, '$1_$2').toLowerCase();
    const nameKC = nameSC.replace(/_/g, '-');
    if (name === nameKC || name === nameSC || name === nameCC) {
      return nameCC;
    }
  }
  return name;
}

class UnknownOption extends Error {
  constructor(key) {
    const adjective = (allOptions[key]) ? 'Unavailable' : 'Unrecognized';
    super(`${adjective} option: ${key}`);
  }
}

async function findConfigFile(name, dir) {
  const path = node_path.join(dir, name);
  try {
    await fs.stat(path);
    return path;
  } catch (err) {
    const parent = node_path.dirname(dir);
    if (parent !== dir) {
      return findConfigFile(name, parent);
    }
  }
}

async function loadConfigFile(cfgPath, availableOptions) {
  const text = await loadFile(cfgPath);
  const json = JSON.parse(text);
  return processConfig(json, cfgPath, availableOptions);
}

function matchesOptionSchema(value, schema) {
  if (schema.anyOf) {
    return schema.anyOf.some(s => matchesOptionSchema(value, s));
  }
  if (schema.type === 'array') {
    if (!Array.isArray(value)) return false;
    return !schema.items || value.every(item => matchesOptionSchema(item, schema.items));
  }
  if (typeof(value) !== schema.type) {
    return false;
  }
  if (schema.enum && !schema.enum.includes(value)) {
    return false;
  }
  return true;
}

function processConfig(object, cfgPath, availableOptions) {
  const options = {};
  for (let [ key, value ] of Object.entries(object)) {
    const option = availableOptions[key];
    if (!option) {
      throw new UnknownOption(key);
    }
    if (!matchesOptionSchema(value, option)) {
      const expected = option.type ?? option.anyOf.map(s => s.type).join('|');
      throw new Error(`${key} is expected to be a ${expected}, received: ${value}`);
    }
    if (key === 'sourceFiles') {
      const modules = {};
      for (const [ modulePath, source ] of Object.entries(value)) {
        modules[modulePath] = { source };
      }
      value = modules;
      key = 'modules';
    }
    if (key === 'buildDir' || key === 'cacheDir' || key === 'moduleDir') {
      value = node_path.resolve(node_path.dirname(cfgPath), value);
    }
    if (key === 'modules') {
      // expand to absolute paths
      const cfgDir = node_path.dirname(cfgPath);
      const modules = {};
      for (let [ modulePath, module ] of Object.entries(value)) {
        modulePath = node_path.resolve(cfgDir, modulePath);
        module.source = node_path.resolve(cfgDir, module.source);
        if (module.loader) {
          module.loader = node_path.resolve(cfgDir, module.loader);
        }
        modules[modulePath] = module;
      }
      value = modules;
    }
    options[key] = value;
  }
  return options;
}

function findSourceFile(modulePath, options) {
  const { modules } = options;
  return modules?.[modulePath]?.source;
}

const statusCharacters = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏';
let statusClear;

function showStatus(message) {
  const fd = 2;
  const tty$1 = tty.isatty(fd);
  let currentCP;
  hideStatus();
  if (tty$1) {
    /* c8 ignore start */
    if (os$1.platform() === 'win32') {
      try {
        const m = /\d+/.exec(child_process.execSync('chcp').toString().trim());
        if (m) {
          currentCP = parseInt(m[0]);
          if (currentCP !== 65001) {
            child_process.execSync('chcp 65001');
          }
        }
      } catch (err) {
      }
    }
    /* c8 ignore end */
    let pos = 0;
    const update = () => {
      const c = statusCharacters.charAt(pos++);
      if (pos >= statusCharacters.length) {
        pos = 0;
      }
      fs$1.write(fd, `\r\x1b[33m${c}\x1b[0m ${message}`, () => {});
    };
    const interval = setInterval(update, 150);
    statusClear = () => {
      clearInterval(interval);
      fs$1.write(fd, '\r\x1b[K', () => {});
      /* c8 ignore start */
      if (currentCP && currentCP !== 65001) {
        try {
          child_process.execSync(`chcp ${currentCP}`);
        } catch (err){
        }
      }
      /* c8 ignore end */
    };
    update();
    /* c8 ignore next 6 */
  } else {
    fs$1.write(fd, message, () => {});
    statusClear = () => {
      fs$1.write(fd, `\b \b`.repeat(message.length), () => {});
    };
  }
}

function hideStatus() {
  statusClear?.();
  statusClear = null;
}

function showResult(message) {
  const fd = 2;
  const tty$1 = tty.isatty(fd);
  const c = '\u2713';
  if (tty$1) {
    fs$1.write(fd, `\r\x1b[32m${c}\x1b[0m ${message}\n`, () => {});
    /* c8 ignore next 3 */
  } else {
    fs$1.write(fd, `${message}\n`, () => {});
  }
}

exports.COMPONENT_HOST_REGISTRY_SYMBOL = COMPONENT_HOST_REGISTRY_SYMBOL;
exports.CORE_VAL_F32 = CORE_VAL_F32;
exports.CORE_VAL_F64 = CORE_VAL_F64;
exports.CORE_VAL_I32 = CORE_VAL_I32;
exports.CORE_VAL_I64 = CORE_VAL_I64;
exports.CORE_VAL_VOID = CORE_VAL_VOID;
exports.HostResourceTable = HostResourceTable;
exports.compile = compile;
exports.createComponentHostWasmImports = createComponentHostWasmImports;
exports.extractOptions = extractOptions;
exports.findConfigFile = findConfigFile;
exports.findSourceFile = findSourceFile;
exports.generateCode = generateCode;
exports.getArch = getArch;
exports.getCachePath = getCachePath;
exports.getComponentHostRegistry = getComponentHostRegistry;
exports.getLibraryExt = getLibraryExt;
exports.getModuleCachePath = getModuleCachePath;
exports.getPlatform = getPlatform;
exports.hideStatus = hideStatus;
exports.instantiateComponentHost = instantiateComponentHost;
exports.loadConfigFile = loadConfigFile;
exports.normalizePath = normalizePath;
exports.optionsForCompile = optionsForCompile;
exports.optionsForTranspile = optionsForTranspile;
exports.processConfig = processConfig;
exports.runComponentHostRpcStdio = runComponentHostRpcStdio;
exports.runTs = runTs;
exports.runWit = runWit;
exports.showResult = showResult;
exports.showStatus = showStatus;
exports.sliceMemoryU8 = sliceMemoryU8;
exports.test = test;
exports.toUnsignedPtr = toUnsignedPtr;
exports.unpackComponent = unpackComponent;
exports.wrapWasiImportsUnsigned = wrapWasiImportsUnsigned;
