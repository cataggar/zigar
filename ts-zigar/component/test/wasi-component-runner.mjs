import fs from "node:fs";
import { WASI } from "node:wasi";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8");

const DIAGNOSTIC_CATEGORIES = ["warning", "error", "suggestion", "message"];

const SCRIPT_TARGETS = {
  es2020: 0,
  es2022: 1,
  es2024: 2,
  esnext: 3,
};

const MODULE_KINDS = {
  commonjs: 0,
  es2020: 1,
  es2022: 2,
  esnext: 3,
  node16: 4,
  nodenext: 5,
  preserve: 6,
};

const MODULE_RESOLUTIONS = {
  bundler: 0,
  node16: 1,
  nodenext: 2,
};

/**
 * Convert a signed 32-bit Wasm linear-memory pointer/offset into an unsigned
 * 32-bit JS integer (`0 .. 0xffff_ffff`), avoiding negative-offset `RangeError`
 * when linear memory grows past 2 GiB (`0x8000_0000`, `nodejs/node#62671`).
 */
export function toUnsignedPtr(ptr) {
  return ptr >>> 0;
}

/**
 * Read a `Uint8Array` view from an `ArrayBufferLike` using unsigned 32-bit
 * pointer/length conversion safe across `>= 2 GiB` (`0x8000_0000+`) addresses.
 */
export function sliceMemoryU8(buffer, ptr, len) {
  const start = toUnsignedPtr(ptr);
  const byteLength = toUnsignedPtr(len);
  return new Uint8Array(buffer, start, byteLength);
}

/**
 * Wrap a `wasi_snapshot_preview1` import table so every numeric Wasm `i32`
 * pointer/size argument is converted to unsigned `u32` (`>>> 0`) before calling
 * into Node's native WASI implementation (`nodejs/node#62671`).
 */
export function wrapWasiImportsUnsigned(rawWasi) {
  const wrapped = {};
  for (const [name, fn] of Object.entries(rawWasi)) {
    if (typeof fn === "function") {
      wrapped[name] = (...args) =>
        fn(...args.map((arg) => (typeof arg === "number" ? arg >>> 0 : arg)));
    } else {
      wrapped[name] = fn;
    }
  }
  if (typeof wrapped.fd_write === "function" && !wrapped["fd_write [v2]"]) {
    wrapped["fd_write [v2]"] = wrapped.fd_write;
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
      throw new Error("Unexpected EOF reading LEB128");
    }
    const byte = bytes[state.pos++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return result >>> 0;
    }
    shift += 7;
  }
}

function readComponentName(bytes, state) {
  // externname ::= 0x00 len:u32 utf8 | 0x01 len:u32 utf8 ...
  const discrim = bytes[state.pos++];
  if (discrim !== 0x00 && discrim !== 0x01) {
    throw new Error(`Unsupported component externname discriminator: 0x${discrim.toString(16)}`);
  }
  const len = readULEB128(bytes, state);
  const str = textDecoder.decode(bytes.subarray(state.pos, state.pos + len));
  state.pos += len;
  return str;
}

/**
 * Parse a WebAssembly Component binary (`\0asm\x0d\x00\x01\x00`) and extract
 * its embedded core modules and top-level export names.
 */
export function extractComponentCoreModules(componentBytes) {
  if (componentBytes.length < 8) {
    throw new Error("Component binary too short");
  }
  const expectedPreamble = [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
  for (let i = 0; i < 8; i++) {
    if (componentBytes[i] !== expectedPreamble[i]) {
      throw new Error(`Invalid component preamble at byte ${i}`);
    }
  }

  const coreModules = [];
  const componentExports = [];
  const state = { pos: 8 };

  while (state.pos < componentBytes.length) {
    const sectionId = componentBytes[state.pos++];
    const sectionSize = readULEB128(componentBytes, state);
    const sectionEnd = state.pos + sectionSize;
    if (sectionEnd > componentBytes.length) {
      throw new Error("Component section exceeds binary length");
    }

    if (sectionId === 1) {
      coreModules.push(componentBytes.subarray(state.pos, sectionEnd));
    } else if (sectionId === 11) {
      const inner = { pos: state.pos };
      const count = readULEB128(componentBytes, inner);
      for (let i = 0; i < count; i++) {
        const exportName = readComponentName(componentBytes, inner);
        componentExports.push(exportName);
        // Remaining bytes of single-entry export section skipped via sectionEnd
        if (count === 1) break;
        const sort = componentBytes[inner.pos++];
        if (sort === 0x00) inner.pos++;
        readULEB128(componentBytes, inner);
        const hasDesc = componentBytes[inner.pos++];
        if (hasDesc !== 0) {
          throw new Error("Multi-entry typed export section requires full type desc walk");
        }
      }
    }

    state.pos = sectionEnd;
  }

  return { coreModules, componentExports };
}

class ResourceTable {
  #nextHandle = 1;
  #reps = new Map();
  #dtor = null;

  bindDtor(dtorFn) {
    this.#dtor = dtorFn;
  }

  insert(rep) {
    const handle = this.#nextHandle++;
    this.#reps.set(handle, toUnsignedPtr(rep));
    return handle;
  }

  rep(handle) {
    const rep = this.#reps.get(handle);
    if (rep === undefined) {
      throw new Error(`Invalid or dropped resource handle: ${handle}`);
    }
    return rep;
  }

  has(handle) {
    return this.#reps.has(handle);
  }

  drop(handle) {
    const rep = this.#reps.get(handle);
    if (rep === undefined) {
      throw new Error(`Double-drop or invalid resource handle: ${handle}`);
    }
    this.#reps.delete(handle);
    if (this.#dtor) {
      this.#dtor(rep);
    }
  }
}

/**
 * Instantiate `typescript-compiler.component.wasm` in Node.js 26 using its
 * embedded Go `wasip1` reactor core module + Canonical ABI bindings.
 */
export function instantiateTypeScriptComponent(wasmPath) {
  const componentBytes = fs.readFileSync(wasmPath);
  const { coreModules, componentExports } = extractComponentCoreModules(componentBytes);
  if (coreModules.length === 0) {
    throw new Error("No core modules found in component");
  }

  const wasi = new WASI({ version: "preview1" });
  const wrappedWasi = wrapWasiImportsUnsigned(wasi.wasiImport);

  const vfsTable = new ResourceTable();
  const programTable = new ResourceTable();
  const checkerTable = new ResourceTable();

  const coreModule = new WebAssembly.Module(coreModules[0]);
  const instance = new WebAssembly.Instance(coreModule, {
    wasi_snapshot_preview1: wrappedWasi,
    "[export]zigar:typescript/compiler@7.1.0": {
      "[resource-new]vfs": (rep) => vfsTable.insert(rep),
      "[resource-rep]vfs": (handle) => vfsTable.rep(handle),
      "[resource-drop]vfs": (handle) => vfsTable.drop(handle),
      "[resource-new]checker": (rep) => checkerTable.insert(rep),
      "[resource-rep]checker": (handle) => checkerTable.rep(handle),
      "[resource-drop]checker": (handle) => checkerTable.drop(handle),
      "[resource-new]program": (rep) => programTable.insert(rep),
      "[resource-rep]program": (handle) => programTable.rep(handle),
      "[resource-drop]program": (handle) => programTable.drop(handle),
    },
  });

  wasi.initialize(instance);

  const exp = instance.exports;
  const memory = exp.memory;
  const cabiRealloc = exp.cabi_realloc;

  vfsTable.bindDtor(exp["zigar:typescript/compiler@7.1.0#[dtor]vfs"]);
  checkerTable.bindDtor(exp["zigar:typescript/compiler@7.1.0#[dtor]checker"]);
  programTable.bindDtor(exp["zigar:typescript/compiler@7.1.0#[dtor]program"]);

  function allocBytes(byteLength, align = 1) {
    if (byteLength === 0) return 0;
    return toUnsignedPtr(cabiRealloc(0, 0, align, byteLength));
  }

  function lowerString(str) {
    const encoded = textEncoder.encode(str);
    if (encoded.byteLength === 0) {
      return { ptr: 0, len: 0 };
    }
    const ptr = allocBytes(encoded.byteLength, 1);
    sliceMemoryU8(memory.buffer, ptr, encoded.byteLength).set(encoded);
    return { ptr, len: encoded.byteLength };
  }

  function lowerStringList(items) {
    if (!items || items.length === 0) {
      return { ptr: 0, len: 0 };
    }
    const lowered = items.map((item) => lowerString(item));
    const listPtr = allocBytes(lowered.length * 8, 4);
    const dv = new DataView(memory.buffer);
    for (let i = 0; i < lowered.length; i++) {
      const base = toUnsignedPtr(listPtr + i * 8);
      dv.setUint32(base, lowered[i].ptr, true);
      dv.setUint32(base + 4, lowered[i].len, true);
    }
    return { ptr: listPtr, len: lowered.length };
  }

  function liftString(buffer, ptr, len) {
    if (len === 0) return "";
    return textDecoder.decode(sliceMemoryU8(buffer, ptr, len));
  }

  function liftStringList(buffer, dv, listPtr, listLen) {
    const p = toUnsignedPtr(listPtr);
    const n = toUnsignedPtr(listLen);
    const out = [];
    for (let i = 0; i < n; i++) {
      const base = p + i * 8;
      const sPtr = dv.getUint32(base, true);
      const sLen = dv.getUint32(base + 4, true);
      out.push(liftString(buffer, sPtr, sLen));
    }
    return out;
  }

  function liftSourceSpan(buffer, dv, baseOffset) {
    const base = toUnsignedPtr(baseOffset);
    const filePtr = dv.getUint32(base, true);
    const fileLen = dv.getUint32(base + 4, true);
    return {
      fileName: liftString(buffer, filePtr, fileLen),
      start: dv.getUint32(base + 8, true),
      length: dv.getUint32(base + 12, true),
      line: dv.getUint32(base + 16, true),
      column: dv.getUint32(base + 20, true),
    };
  }

  function liftDiagnosticList(buffer, dv, listPtr, listLen) {
    const p = toUnsignedPtr(listPtr);
    const n = toUnsignedPtr(listLen);
    const diags = [];
    for (let i = 0; i < n; i++) {
      const base = p + i * 52;
      const code = dv.getUint32(base, true);
      const catIdx = dv.getUint8(base + 4);
      const msgPtr = dv.getUint32(base + 8, true);
      const msgLen = dv.getUint32(base + 12, true);
      const spanTag = dv.getUint8(base + 16);
      const span = spanTag === 1 ? liftSourceSpan(buffer, dv, base + 20) : null;
      const relPtr = toUnsignedPtr(dv.getUint32(base + 44, true));
      const relLen = toUnsignedPtr(dv.getUint32(base + 48, true));
      const relatedSpans = [];
      for (let j = 0; j < relLen; j++) {
        relatedSpans.push(liftSourceSpan(buffer, dv, relPtr + j * 24));
      }
      diags.push({
        code,
        category: DIAGNOSTIC_CATEGORIES[catIdx] ?? `unknown(${catIdx})`,
        message: liftString(buffer, msgPtr, msgLen),
        span,
        relatedSpans,
      });
    }
    return diags;
  }

  function liftEmitOutput(retPtr, postFn) {
    const rp = toUnsignedPtr(retPtr);
    const buffer = memory.buffer;
    const dv = new DataView(buffer);
    const filesPtr = toUnsignedPtr(dv.getUint32(rp, true));
    const filesLen = toUnsignedPtr(dv.getUint32(rp + 4, true));
    const outputFiles = [];
    for (let i = 0; i < filesLen; i++) {
      const base = filesPtr + i * 16;
      const namePtr = dv.getUint32(base, true);
      const nameLen = dv.getUint32(base + 4, true);
      const contentsPtr = dv.getUint32(base + 8, true);
      const contentsLen = dv.getUint32(base + 12, true);
      outputFiles.push({
        fileName: liftString(buffer, namePtr, nameLen),
        contents: liftString(buffer, contentsPtr, contentsLen),
      });
    }
    const diagsPtr = dv.getUint32(rp + 8, true);
    const diagsLen = dv.getUint32(rp + 12, true);
    const diagnostics = liftDiagnosticList(buffer, dv, diagsPtr, diagsLen);
    const emitSkipped = dv.getUint8(rp + 16) !== 0;
    postFn(rp);
    return { outputFiles, diagnostics, emitSkipped };
  }

  function liftSymbolInfoAt(buffer, dv, baseOffset) {
    const base = toUnsignedPtr(baseOffset);
    const name = liftString(buffer, dv.getUint32(base, true), dv.getUint32(base + 4, true));
    const qualifiedName = liftString(buffer, dv.getUint32(base + 8, true), dv.getUint32(base + 12, true));
    const symbolFlags = dv.getUint32(base + 16, true);
    const typeText = liftString(buffer, dv.getUint32(base + 20, true), dv.getUint32(base + 24, true));
    const docTag = dv.getUint8(base + 28);
    const documentation =
      docTag === 1
        ? liftString(buffer, dv.getUint32(base + 32, true), dv.getUint32(base + 36, true))
        : null;
    const spanTag = dv.getUint8(base + 40);
    const declarationSpan = spanTag === 1 ? liftSourceSpan(buffer, dv, base + 44) : null;
    return {
      name,
      qualifiedName,
      symbolFlags,
      typeText,
      documentation,
      declarationSpan,
    };
  }

  class VfsHandle {
    #handle;
    constructor(handle) {
      this.#handle = handle;
    }
    get handle() {
      return this.#handle;
    }
    get rep() {
      return vfsTable.rep(this.#handle);
    }
    writeFile(filePath, contents) {
      const p = lowerString(filePath);
      const c = lowerString(contents);
      exp["zigar:typescript/compiler@7.1.0#[method]vfs.write-file"](
        this.rep,
        p.ptr,
        p.len,
        c.ptr,
        c.len,
      );
    }
    readFile(filePath) {
      const p = lowerString(filePath);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]vfs.read-file"](this.rep, p.ptr, p.len),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const tag = dv.getUint8(retPtr);
      const value =
        tag === 1 ? liftString(buffer, dv.getUint32(retPtr + 4, true), dv.getUint32(retPtr + 8, true)) : null;
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]vfs.read-file"](retPtr);
      return value;
    }
    fileExists(filePath) {
      const p = lowerString(filePath);
      return (
        exp["zigar:typescript/compiler@7.1.0#[method]vfs.file-exists"](this.rep, p.ptr, p.len) !== 0
      );
    }
    deleteFile(filePath) {
      const p = lowerString(filePath);
      return (
        exp["zigar:typescript/compiler@7.1.0#[method]vfs.delete-file"](this.rep, p.ptr, p.len) !== 0
      );
    }
    listFiles(dirPath = "/") {
      const p = lowerString(dirPath);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]vfs.list-files"](this.rep, p.ptr, p.len),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const list = liftStringList(
        buffer,
        dv,
        dv.getUint32(retPtr, true),
        dv.getUint32(retPtr + 4, true),
      );
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]vfs.list-files"](retPtr);
      return list;
    }
    drop() {
      if (vfsTable.has(this.#handle)) {
        vfsTable.drop(this.#handle);
      }
    }
    [Symbol.dispose]() {
      this.drop();
    }
  }

  class CheckerHandle {
    #handle;
    constructor(handle) {
      this.#handle = handle;
    }
    get handle() {
      return this.#handle;
    }
    get rep() {
      return checkerTable.rep(this.#handle);
    }
    typeToString(fileName, offset) {
      const f = lowerString(fileName);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]checker.type-to-string"](
          this.rep,
          f.ptr,
          f.len,
          offset >>> 0,
        ),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const tag = dv.getUint8(retPtr);
      const value =
        tag === 1 ? liftString(buffer, dv.getUint32(retPtr + 4, true), dv.getUint32(retPtr + 8, true)) : null;
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]checker.type-to-string"](retPtr);
      return value;
    }
    inspectTypeAt(fileName, offset) {
      const f = lowerString(fileName);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]checker.inspect-type-at"](
          this.rep,
          f.ptr,
          f.len,
          offset >>> 0,
        ),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const tag = dv.getUint8(retPtr);
      let info = null;
      if (tag === 1) {
        const typeText = liftString(
          buffer,
          dv.getUint32(retPtr + 4, true),
          dv.getUint32(retPtr + 8, true),
        );
        const typeFlags = dv.getUint32(retPtr + 12, true);
        const isNullable = dv.getUint8(retPtr + 16) !== 0;
        const isUnion = dv.getUint8(retPtr + 17) !== 0;
        const isIntersection = dv.getUint8(retPtr + 18) !== 0;
        const spanTag = dv.getUint8(retPtr + 20);
        const span = spanTag === 1 ? liftSourceSpan(buffer, dv, retPtr + 24) : null;
        info = { typeText, typeFlags, isNullable, isUnion, isIntersection, span };
      }
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]checker.inspect-type-at"](retPtr);
      return info;
    }
    inspectSymbolAt(fileName, offset) {
      const f = lowerString(fileName);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]checker.inspect-symbol-at"](
          this.rep,
          f.ptr,
          f.len,
          offset >>> 0,
        ),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const tag = dv.getUint8(retPtr);
      const info = tag === 1 ? liftSymbolInfoAt(buffer, dv, retPtr + 4) : null;
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]checker.inspect-symbol-at"](retPtr);
      return info;
    }
    resolveModuleExports(fileName) {
      const f = lowerString(fileName);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]checker.resolve-module-exports"](
          this.rep,
          f.ptr,
          f.len,
        ),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const listPtr = toUnsignedPtr(dv.getUint32(retPtr, true));
      const listLen = toUnsignedPtr(dv.getUint32(retPtr + 4, true));
      const items = [];
      for (let i = 0; i < listLen; i++) {
        items.push(liftSymbolInfoAt(buffer, dv, listPtr + i * 68));
      }
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]checker.resolve-module-exports"](retPtr);
      return items;
    }
    drop() {
      if (checkerTable.has(this.#handle)) {
        checkerTable.drop(this.#handle);
      }
    }
    [Symbol.dispose]() {
      this.drop();
    }
  }

  class ProgramHandle {
    #handle;
    constructor(handle) {
      this.#handle = handle;
    }
    get handle() {
      return this.#handle;
    }
    get rep() {
      return programTable.rep(this.#handle);
    }
    getRootFiles() {
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]program.get-root-files"](this.rep),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const files = liftStringList(
        buffer,
        dv,
        dv.getUint32(retPtr, true),
        dv.getUint32(retPtr + 4, true),
      );
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]program.get-root-files"](retPtr);
      return files;
    }
    #getDiagnostics(exportName, postName, fileName = null) {
      const optTag = fileName == null ? 0 : 1;
      const f = fileName == null ? { ptr: 0, len: 0 } : lowerString(fileName);
      const retPtr = toUnsignedPtr(exp[exportName](this.rep, optTag, f.ptr, f.len));
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const diags = liftDiagnosticList(
        buffer,
        dv,
        dv.getUint32(retPtr, true),
        dv.getUint32(retPtr + 4, true),
      );
      exp[postName](retPtr);
      return diags;
    }
    getSyntacticDiagnostics(fileName = null) {
      return this.#getDiagnostics(
        "zigar:typescript/compiler@7.1.0#[method]program.get-syntactic-diagnostics",
        "cabi_post_zigar:typescript/compiler@7.1.0#[method]program.get-syntactic-diagnostics",
        fileName,
      );
    }
    getSemanticDiagnostics(fileName = null) {
      return this.#getDiagnostics(
        "zigar:typescript/compiler@7.1.0#[method]program.get-semantic-diagnostics",
        "cabi_post_zigar:typescript/compiler@7.1.0#[method]program.get-semantic-diagnostics",
        fileName,
      );
    }
    getGlobalDiagnostics() {
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/compiler@7.1.0#[method]program.get-global-diagnostics"](this.rep),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const diags = liftDiagnosticList(
        buffer,
        dv,
        dv.getUint32(retPtr, true),
        dv.getUint32(retPtr + 4, true),
      );
      exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]program.get-global-diagnostics"](retPtr);
      return diags;
    }
    emitDeclarations(fileName = null) {
      const optTag = fileName == null ? 0 : 1;
      const f = fileName == null ? { ptr: 0, len: 0 } : lowerString(fileName);
      const retPtr = exp["zigar:typescript/compiler@7.1.0#[method]program.emit-declarations"](
        this.rep,
        optTag,
        f.ptr,
        f.len,
      );
      return liftEmitOutput(
        retPtr,
        exp["cabi_post_zigar:typescript/compiler@7.1.0#[method]program.emit-declarations"],
      );
    }
    getChecker() {
      const checkerHandle = exp["zigar:typescript/compiler@7.1.0#[method]program.get-checker"](
        this.rep,
      );
      return new CheckerHandle(checkerHandle);
    }
    drop() {
      if (programTable.has(this.#handle)) {
        programTable.drop(this.#handle);
      }
    }
    [Symbol.dispose]() {
      this.drop();
    }
  }

  return {
    componentExports,
    memory,

    compilerVersion() {
      const retPtr = toUnsignedPtr(exp["zigar:typescript/compiler@7.1.0#compiler-version"]());
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const ver = liftString(buffer, dv.getUint32(retPtr, true), dv.getUint32(retPtr + 4, true));
      exp["cabi_post_zigar:typescript/compiler@7.1.0#compiler-version"](retPtr);
      return ver;
    },

    createVfs(useBundledLibs = true) {
      const handle = exp["zigar:typescript/compiler@7.1.0#[constructor]vfs"](useBundledLibs ? 1 : 0);
      return new VfsHandle(handle);
    },

    createProgram(vfs, rootFiles, options = {}) {
      const loweredRoots = lowerStringList(rootFiles);
      const loweredBaseUrl =
        options.baseUrl != null ? lowerString(options.baseUrl) : null;
      const loweredTypeRoots = lowerStringList(options.typeRoots ?? []);
      const loweredTypes = lowerStringList(options.types ?? []);

      const argPtr = allocBytes(52, 4);
      const dv = new DataView(memory.buffer);
      dv.setUint32(argPtr, vfs.rep, true);
      dv.setUint32(argPtr + 4, loweredRoots.ptr, true);
      dv.setUint32(argPtr + 8, loweredRoots.len, true);
      dv.setUint8(argPtr + 12, SCRIPT_TARGETS[options.target ?? "esnext"] ?? 3);
      dv.setUint8(argPtr + 13, MODULE_KINDS[options.module ?? "esnext"] ?? 3);
      dv.setUint8(argPtr + 14, MODULE_RESOLUTIONS[options.moduleResolution ?? "bundler"] ?? 0);
      dv.setUint8(argPtr + 15, (options.strict ?? true) ? 1 : 0);
      dv.setUint8(argPtr + 16, (options.exactOptionalPropertyTypes ?? false) ? 1 : 0);
      dv.setUint8(argPtr + 17, (options.noUncheckedIndexedAccess ?? false) ? 1 : 0);
      dv.setUint8(argPtr + 18, (options.declaration ?? true) ? 1 : 0);
      dv.setUint8(argPtr + 19, (options.emitDeclarationOnly ?? false) ? 1 : 0);
      dv.setUint8(argPtr + 20, (options.allowJs ?? false) ? 1 : 0);
      dv.setUint8(argPtr + 21, (options.skipLibCheck ?? true) ? 1 : 0);
      dv.setUint8(argPtr + 24, loweredBaseUrl ? 1 : 0);
      dv.setUint32(argPtr + 28, loweredBaseUrl ? loweredBaseUrl.ptr : 0, true);
      dv.setUint32(argPtr + 32, loweredBaseUrl ? loweredBaseUrl.len : 0, true);
      dv.setUint32(argPtr + 36, loweredTypeRoots.ptr, true);
      dv.setUint32(argPtr + 40, loweredTypeRoots.len, true);
      dv.setUint32(argPtr + 44, loweredTypes.ptr, true);
      dv.setUint32(argPtr + 48, loweredTypes.len, true);

      const retPtr = toUnsignedPtr(exp["zigar:typescript/compiler@7.1.0#create-program"](argPtr));
      const outBuf = memory.buffer;
      const outDv = new DataView(outBuf);
      const tag = outDv.getUint8(retPtr);
      let outcome;
      if (tag === 0) {
        const progHandle = outDv.getUint32(retPtr + 4, true);
        outcome = { ok: true, value: new ProgramHandle(progHandle) };
      } else {
        const errDiags = liftDiagnosticList(
          outBuf,
          outDv,
          outDv.getUint32(retPtr + 4, true),
          outDv.getUint32(retPtr + 8, true),
        );
        outcome = { ok: false, error: errDiags };
      }
      exp["cabi_post_zigar:typescript/compiler@7.1.0#create-program"](retPtr);
      return outcome;
    },

    transpileModule(source, fileName = "/module.ts") {
      const s = lowerString(source);
      const f = lowerString(fileName);
      const retPtr = exp["zigar:typescript/compiler@7.1.0#transpile-module"](
        s.ptr,
        s.len,
        f.ptr,
        f.len,
      );
      return liftEmitOutput(
        retPtr,
        exp["cabi_post_zigar:typescript/compiler@7.1.0#transpile-module"],
      );
    },

    extractModuleGraph(program, config = {}) {
      const roots = lowerStringList(config.rootFiles ?? []);
      const specs = lowerStringList(config.moduleSpecifiers ?? []);
      const retPtr = toUnsignedPtr(
        exp["zigar:typescript/extractor@7.1.0#extract-module-graph"](
          program.rep,
          roots.ptr,
          roots.len,
          specs.ptr,
          specs.len,
          (config.followReExports ?? true) ? 1 : 0,
          (config.expandUtilityTypes ?? false) ? 1 : 0,
          (config.includeJsdoc ?? true) ? 1 : 0,
          (config.includePrivateMembers ?? false) ? 1 : 0,
        ),
      );
      const buffer = memory.buffer;
      const dv = new DataView(buffer);
      const tag = dv.getUint8(retPtr);
      let outcome;
      if (tag === 0) {
        const strings = liftStringList(
          buffer,
          dv,
          dv.getUint32(retPtr + 4, true),
          dv.getUint32(retPtr + 8, true),
        );
        const modulesLen = dv.getUint32(retPtr + 16, true);
        const entryPtr = toUnsignedPtr(dv.getUint32(retPtr + 20, true));
        const entryLen = toUnsignedPtr(dv.getUint32(retPtr + 24, true));
        const entryModules = [];
        for (let i = 0; i < entryLen; i++) {
          entryModules.push(dv.getUint32(entryPtr + i * 4, true));
        }
        const diagnostics = liftDiagnosticList(
          buffer,
          dv,
          dv.getUint32(retPtr + 68, true),
          dv.getUint32(retPtr + 72, true),
        );
        outcome = {
          ok: true,
          value: { strings, modulesLen, entryModules, diagnostics },
        };
      } else {
        const diagnostics = liftDiagnosticList(
          buffer,
          dv,
          dv.getUint32(retPtr + 4, true),
          dv.getUint32(retPtr + 8, true),
        );
        outcome = { ok: false, error: diagnostics };
      }
      exp["cabi_post_zigar:typescript/extractor@7.1.0#extract-module-graph"](retPtr);
      return outcome;
    },
  };
}
