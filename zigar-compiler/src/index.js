export { generateCode } from './code-generation.js';
export { compile, getCachePath, getModuleCachePath, runTs, runWit, test } from './compilation.js';
export {
  COMPONENT_HOST_REGISTRY_SYMBOL, CORE_VAL_F32, CORE_VAL_F64, CORE_VAL_I32, CORE_VAL_I64,
  CORE_VAL_VOID, createComponentHostWasmImports, getComponentHostRegistry, HostResourceTable,
  instantiateComponentHost, runComponentHostRpcStdio, sliceMemoryU8, toUnsignedPtr,
  unpackComponent, wrapWasiImportsUnsigned
} from './component-host.js';
export {
  extractOptions, findConfigFile, findSourceFile, loadConfigFile, optionsForCompile,
  optionsForTranspile, processConfig
} from './configuration.js';
export { hideStatus, showResult, showStatus } from './status.js';
export { getArch, getLibraryExt, getPlatform, normalizePath } from './utility-functions.js';

