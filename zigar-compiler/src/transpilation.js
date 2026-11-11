import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { defineEnvironment } from '../../zigar-runtime/src/environment.js';
import * as mixins from '../../zigar-runtime/src/mixins.js';
import { generateCode } from './code-generation.js';
import { compile } from './compilation.js';
import {
  analyzeJspiSyncFunctions,
  ensureStackPointerExport,
  extractLimits,
  stripUnused,
} from './wasm-decoding.js';

export async function transpile(srcPath, options) {
  const {
    nodeCompat = false,
    embedWASM = true,
    topLevelAwait = true,
    omitExports = false,
    stripWASM = (options.optimize && options.optimize !== 'Debug'),
    keepNames = false,
    useJSPI = false,
    continuationStackSize,
    memory64 = false,
    useResizableBuffer,
    moduleResolver = (name) => name,
    wasmLoader,
    ...compileOptions
  } = options;
  if (typeof(wasmLoader) !== 'function') {
    if (embedWASM !== true) {
      throw new Error(`wasmLoader is a required option when embedWASM is false`);
    }
  }
  Object.assign(compileOptions, {
    arch: memory64 ? 'wasm64' : 'wasm32',
    platform: 'wasi',
    isWASM: true,
    memory64,
    useResizableBuffer,
  });
  const { outputPath, sourcePaths } = await compile(srcPath, null, compileOptions);
  const content = await readFile(outputPath);
  const rawDV = new DataView(content.buffer, content.byteOffset, content.byteLength);
  const limits = extractLimits(rawDV);
  const isMemory64 = Boolean(memory64 || limits.memory64);
  const isTable64 = Boolean(limits.table64);
  const memoryMax = (limits.memoryMax !== undefined) ? Number(limits.memoryMax) : undefined;
  const memoryInitial = (limits.memoryInitial !== undefined) ? Number(limits.memoryInitial) : undefined;
  const tableInitial = (limits.tableInitial !== undefined) ? Number(limits.tableInitial) : undefined;
  const { multithreaded = false } = compileOptions;
  const moduleOptions = {
    memoryMax,
    memoryInitial,
    tableInitial,
    multithreaded,
  };
  if (isMemory64) {
    moduleOptions.memory64 = true;
  }
  if (isTable64) {
    moduleOptions.table64 = true;
  }
  if (useResizableBuffer === false) {
    moduleOptions.useResizableBuffer = false;
  }
  if (useJSPI) {
    moduleOptions.useJSPI = useJSPI;
  }
  if (continuationStackSize !== undefined) {
    moduleOptions.continuationStackSize = continuationStackSize;
  }
  const Env = defineEnvironment();
  const env = new Env();
  env.loadModule(content, moduleOptions);
  await env.initPromise;
  env.acquireStructures();
  const definition = env.exportStructures();
  if (isMemory64) {
    definition.settings = { ...definition.settings, memory64: true };
  } else if (definition.settings && !definition.settings.memory64) {
    delete definition.settings.memory64;
  }
  const usage = {};
  for (const [ name, mixin ] of Object.entries(mixins)) {
    if (env.mixinUsage.get(mixin) && name !== 'FeatureStructureAcquisition') {
      usage[name] = true;
    }
  }
  if (nodeCompat && usage.FeatureWorkerSupport) {
    usage.FeatureWorkerSupportCompat = true;
    usage.FeatureWorkerSupport = false;
  }
  const mixinPaths = [];
  for (const [ name, inUse ] of Object.entries(usage)) {
    if (inUse) {
      // change name to snake_case
      const parts = name.replace(/\B([A-Z])/g, ' $1').toLowerCase().split(' ');
      const type = parts.shift();
      const dir =  (type === 'wasi') ? 'wasi' : `${type}s`;
      const filename = parts.join('-') + '.js';
      mixinPaths.push(`${dir}/${filename}`);
    }
  }
  const runtimeURL = moduleResolver('zigar-runtime');
  let binarySource;
  if (env.hasMethods()) {
    if (useJSPI && useJSPI !== 'all') {
      moduleOptions.syncFunctions = analyzeJspiSyncFunctions(rawDV);
    }
    let dv = rawDV;
    if (stripWASM) {
      dv = stripUnused(dv, { keepNames });
    } else {
      dv = ensureStackPointerExport(dv);
    }
    if (embedWASM) {
      binarySource = embed(srcPath, dv);
    } else {
      binarySource = await wasmLoader(srcPath, dv);
    }
  }
  const { code, exports, structures } = generateCode(definition, {
    declareFeatures: true,
    runtimeURL,
    binarySource,
    topLevelAwait,
    omitExports,
    moduleOptions,
    mixinPaths,
  });
  return { code, exports, structures, sourcePaths };
}

function embed(path, dv) {
  const base64 = Buffer.from(dv.buffer, dv.byteOffset, dv.byteLength).toString('base64');
  return `(async () => {
  // ${basename(path)}
  const binaryString = atob(${JSON.stringify(base64)});
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  await new Promise(r => setTimeout(r, 0));
  return bytes.buffer;
})()`;
}
