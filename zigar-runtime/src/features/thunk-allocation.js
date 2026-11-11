import { mixin } from '../environment.js';
import { empty } from '../utils.js';

export default mixin({
  ...(process.env.TARGET === 'wasm' ? {
    exports: {
      allocateJsThunk: { argType: 'az', returnType: 'a' },
      freeJsThunk: { argType: 'aa', returnType: 'z' },
      findJsThunk: { argType: 'aa', returnType: 'z' },
    },
    imports: {
      identifyJsThunk: { argType: 'aa', returnType: 'z' },
    },
    init() {
      this.thunkSources = [];
      this.thunkMap = new Map();
    },
    addJsThunkSource() {
      const {
        memoryInitial,
        memoryMax,
        tableInitial,
        multithreaded,
      } = this.options ?? {};
      const w = WebAssembly;
      const env = {}, wasi = {}, wasiPreview = {};
      const imports = { env, wasi, wasi_snapshot_preview1: wasiPreview };
      for (const { module, name, kind } of w.Module.imports(this.executable)) {
        if (kind === 'function') {
          if (module === 'env') {
            env[name] = empty;
          } else if (module === 'wasi_snapshot_preview1') {
            wasiPreview[name] = empty;
          }
        }
      }
      const initialPages = memoryInitial ?? (this.memory.buffer.byteLength / 65536);
      env.memory = new w.Memory(this.memory64 ? {
        initial: BigInt(initialPages),
        ...(memoryMax !== undefined ? { maximum: BigInt(memoryMax) } : undefined),
        shared: multithreaded,
        address: 'i64',
      } : {
        initial: initialPages,
        maximum: memoryMax,
        shared: multithreaded,
      });
      let table;
      const initialTable = tableInitial || this.initialTableLength;
      if (initialTable) {
        table = env.__indirect_function_table = new w.Table(this.table64 ? {
          initial: BigInt(initialTable),
          element: 'anyfunc',
          address: 'i64',
        } : {
          initial: initialTable,
          element: 'anyfunc',
        });
      }
      const { exports } = new w.Instance(this.executable, imports);
      table ??= exports.__indirect_function_table;
      const createJsThunk = exports.createJsThunk && this.importFunction(exports.createJsThunk, 'az', 'a');
      const destroyJsThunk = exports.destroyJsThunk && this.importFunction(exports.destroyJsThunk, 'aa', 'z');
      const identifyJsThunk = exports.identifyJsThunk && this.importFunction(exports.identifyJsThunk, 'aa', 'z');
      const source = {
        thunkCount: 0,
        createJsThunk,
        destroyJsThunk,
        identifyJsThunk,
        table,
      };
      this.thunkSources.unshift(source);
      return source;
    },
    allocateJsThunk(controllerAddress, funcId) {
      let source, sourceAddress = 0;
      for (source of this.thunkSources) {
        sourceAddress = source.createJsThunk(controllerAddress, funcId);
        break;
      }
      if (!sourceAddress) {
        source = this.addJsThunkSource();
        sourceAddress = source.createJsThunk(controllerAddress, funcId);
      }
      // sourceAddress is an index into the function table of the source instance
      // we need to get the function object and place it into the main instance's
      // function table
      const isSourceTable64 = typeof source.table.length === 'bigint';
      const thunkObject = source.table.get(isSourceTable64 ? BigInt(sourceAddress) : Number(sourceAddress));
      const isTable64 = typeof this.table.length === 'bigint';
      const tableLen = Number(this.table.length);
      const initialLen = Number(this.initialTableLength);
      let thunkIndex = 0;
      for (let i = tableLen - 1; i >= initialLen; i--) {
        if (!this.table.get(isTable64 ? BigInt(i) : i)) {
          thunkIndex = i;
          break;
        }
      }
      if (!thunkIndex) {
        thunkIndex = tableLen;
        this.table.grow(isTable64 ? 8n : 8);
      }
      this.table.set(isTable64 ? BigInt(thunkIndex) : thunkIndex, thunkObject);
      source.thunkCount++;
      // remember where the object is from
      this.thunkMap.set(thunkObject, { source, sourceAddress });
      return (this.memory64 || isTable64) ? BigInt(thunkIndex) : thunkIndex;
    },
    freeJsThunk(controllerAddress, thunkAddress) {
      let fnId = 0;
      const isTable64 = typeof this.table.length === 'bigint';
      const tableIdx = isTable64 ? BigInt(thunkAddress) : Number(thunkAddress);
      const thunkObject = this.table.get(tableIdx);
      this.table.set(tableIdx, null);
      const entry = this.thunkMap.get(thunkObject);
      if (entry) {
        const { source, sourceAddress } = entry;
        fnId = Number(source.destroyJsThunk(controllerAddress, sourceAddress));
        if (--source.thunkCount === 0) {
          const index = this.thunkSources.indexOf(source);
          if (index !== -1) {
            this.thunkSources.splice(index, 1);
          }
        }
        this.thunkMap.delete(thunkObject);
      }
      return fnId;
    },
    findJsThunk(controllerAddress, thunkAddress) {
      let fnId = 0;
      const isTable64 = typeof this.table.length === 'bigint';
      const tableIdx = isTable64 ? BigInt(thunkAddress) : Number(thunkAddress);
      const thunkObject = this.table.get(tableIdx);
      this.table.set(tableIdx, null);
      const entry = this.thunkMap.get(thunkObject);
      if (entry) {
        const { source, sourceAddress } = entry;
        fnId = Number(source.identifyJsThunk(controllerAddress, sourceAddress));
      }
      return fnId;
    },
  } : undefined),
});
