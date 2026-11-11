import { expect } from 'chai';
import { readFile, readdir } from 'fs/promises';
import { fileURLToPath } from 'url';

import {
  MagicNumber,
  ObjectType,
  SectionType,
  analyzeJspiSyncFunctions,
  ensureStackPointerExport,
  extractLimits,
  parseBinary,
  parseFunction,
  parseNames,
  repackBinary,
  repackFunction,
  repackNames,
  stripUnused,
} from '../src/wasm-decoding.js';
import { compile, getModuleCachePath } from '../src/compilation.js';

const littleEndian = true;

describe('WASM decoding', function() {
  this.timeout(0);
  describe('parseBinary', function() {
    it('should parse WASM files', async function() {
      const wasmFiles = [
        'fail',
        'global',
        'memory',
        'simple',
        'table',
        'table2',
      ].map(name => absolute(`./wasm-samples/${name}.wasm`));
      for (const path of wasmFiles) {
        const content = await readFile(path);
        const binary = new DataView(content.buffer);
        const module = parseBinary(binary);
        expect(module.sections).to.be.an('array');
      }
    })
    it('should throw when the magic number is incorrect', async function() {
      const binary = new DataView(new ArrayBuffer(8));
      expect(() => parseBinary(binary)).to.throw();
    })
    it('should throw when the version number is incorrect', async function() {
      const binary = new DataView(new ArrayBuffer(8));
      binary.setUint32(0, MagicNumber, true);
      expect(() => parseBinary(binary)).to.throw();
    })
  })
  describe('repackBinary', function() {
    it('should recreate WASM binary', async function() {
      const wasmFiles = [
        'fail',
        'global',
        'memory',
        'simple',
        'table',
        'table2',
      ].map(name => absolute(`./wasm-samples/${name}.wasm`));
      for (const path of wasmFiles) {
        const content = await readFile(path);
        const binary = new DataView(content.buffer);
        const module = parseBinary(binary);
        const newBinary = repackBinary(module);
        expect(newBinary.byteLength).to.equal(binary.byteLength);
        for (let i = 0; i < newBinary.byteLength; i++) {
          expect(newBinary.getUint8(i)).to.equal(binary.getUint8(i));
        }
      }
    })
    it('should recreate WASM files from WABT test suite', async function() {
      const dir = absolute(`./wasm-samples/wabt-test-suite`);
      const names = await readdir(dir);
      const wasmFiles = names.filter(n => /\.wasm$/.test(n)).map(n => `${dir}/${n}`);
      for (const path of wasmFiles) {
        const content = await readFile(path);
        const binary = new DataView(content.buffer);
        const module = parseBinary(binary);
        const newBinary = repackBinary(module);
        expect(newBinary.byteLength).to.equal(binary.byteLength);
        for (let i = 0; i < newBinary.byteLength; i++) {
          expect(newBinary.getUint8(i)).to.equal(binary.getUint8(i));
        }
      }
    })
  })
  describe('parseFunction', function() {
    it('should parse a function body in the code section', async function() {
      const path = absolute(`./wasm-samples/fail.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const module = parseBinary(binary);
      const codeSection = module.sections.find(s => s.type === SectionType.Code);
      expect(codeSection).to.not.be.undefined;
      const { functions: [ fn ] } = codeSection;
      expect(fn).be.an.instanceOf(DataView);
      const { locals, instructions } = parseFunction(fn);
      expect(locals).to.be.an('array').with.lengthOf(0);
      expect(instructions).to.be.an('array').with.lengthOf(4);
      const [ instr1, instr2, instr3, instr4 ] = instructions;
      expect(instr1).to.eql({ opcode: 65, operand: 1 });  // load i32
      expect(instr2).to.eql({ opcode: 65, operand: 0 });  // load i32
      expect(instr3).to.eql({ opcode: 109, operand: undefined });  // div
      expect(instr4).to.eql({ opcode: 11, operand: undefined });  // end
    })
  })
  describe('repackFunction', function() {
    it('should recreate function body', async function() {
      const path = absolute(`./wasm-samples/fail.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const module = parseBinary(binary);
      const codeSection = module.sections.find(s => s.type === SectionType.Code);
      expect(codeSection).to.not.be.undefined;
      const { functions: [ fn ] } = codeSection;
      expect(fn).be.an.instanceOf(DataView);
      const result = parseFunction(fn);
      const newFn = repackFunction(result);
      expect(newFn).to.be.an.instanceOf(DataView);
      expect(newFn.byteLength).to.equal(fn.byteLength);
      for (let i = 0; i < newFn.byteLength; i++) {
        expect(newFn.getUint8(i)).to.equal(fn.getUint8(i));
      }
    })
    it('should handle more complicated file', async function() {
      const path = absolute(`./wasm-samples/ziglyph.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const module = parseBinary(binary);
      const codeSection = module.sections.find(s => s.type === SectionType.Code);
      expect(codeSection).to.not.be.undefined;
      const { functions } = codeSection;
      for (const [ index, fn ] of functions.entries()) {
        expect(fn).be.an.instanceOf(DataView);
        const result = parseFunction(fn);
        const newFn = repackFunction(result);
        expect(newFn).to.be.an.instanceOf(DataView);
        expect(newFn.byteLength).to.equal(fn.byteLength);
        for (let i = 0; i < newFn.byteLength; i++) {
          expect(newFn.getUint8(i)).to.equal(fn.getUint8(i));
        }
      }
    })
    it('should repack code from WABT test suite', async function() {
      const dir = absolute(`./wasm-samples/wabt-test-suite`);
      const names = await readdir(dir);
      const wasmFiles = names.filter(n => /\.wasm$/.test(n)).map(n => `${dir}/${n}`);
      for (const path of wasmFiles) {
        const content = await readFile(path);
        const binary = new DataView(content.buffer);
        const module = parseBinary(binary);
        const codeSection = module.sections.find(s => s.type === SectionType.Code);
        if (codeSection) {
          const { functions } = codeSection;
          for (const [ index, fn ] of functions.entries()) {
            expect(fn).be.an.instanceOf(DataView);
            const result = parseFunction(fn);
            const newFn = repackFunction(result);
            expect(newFn.byteLength).to.equal(fn.byteLength);
            for (let i = 0; i < newFn.byteLength; i++) {
              expect(newFn.getUint8(i)).to.equal(fn.getUint8(i));
            }
          }
        }
      }
    })
  })
  describe('stripUnused', function() {
    it('should remove unused functions', async function() {
      const path = absolute(`./wasm-samples/simple-original.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const newBinary = stripUnused(binary);
      expect(newBinary.byteLength).to.be.below(binary.byteLength);
    })
    it('should retain names when keepNames is true', async function() {
      const path = absolute(`./wasm-samples/simple-with-names.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const newBinary = stripUnused(binary, { keepNames: true });
      const module = parseBinary(newBinary);
      const nameSection = module.sections.find(s => s.type === SectionType.Custom);
      expect(nameSection).to.not.be.undefined;
      expect(nameSection).to.have.property('name', 'name');
    })
    it('should preserve zigar:abi and component-type custom sections while stripping others', async function() {
      const path = absolute(`./wasm-samples/simple-with-names.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const origModule = parseBinary(binary);
      const origCodeSection = origModule.sections.find(s => s.type === SectionType.Code);
      const abiPayload = new Uint8Array([ 1, 2, 3, 4 ]);
      const witPayload = new Uint8Array([ 5, 6, 7, 8 ]);
      const otherPayload = new Uint8Array([ 9, 10 ]);
      origModule.sections.push(
        { type: SectionType.Custom, name: 'zigar:abi', data: new DataView(abiPayload.buffer) },
        { type: SectionType.Custom, name: 'component-type:test-world', data: new DataView(witPayload.buffer) },
        { type: SectionType.Custom, name: 'producers', data: new DataView(otherPayload.buffer) },
      );
      const inputBinary = repackBinary({ sections: origModule.sections, size: origModule.size + 256 });
      const newBinary = stripUnused(inputBinary);
      expect(newBinary.byteLength).to.be.below(inputBinary.byteLength);
      const strippedModule = parseBinary(newBinary);
      const strippedCodeSection = strippedModule.sections.find(s => s.type === SectionType.Code);
      expect(strippedCodeSection.functions.length).to.be.below(origCodeSection.functions.length);
      const customSections = strippedModule.sections.filter(s => s.type === SectionType.Custom);
      expect(customSections.map(s => s.name)).to.eql([ 'zigar:abi', 'component-type:test-world' ]);
      expect([ ...new Uint8Array(customSections[0].data.buffer, customSections[0].data.byteOffset, customSections[0].data.byteLength) ]).to.eql([ 1, 2, 3, 4 ]);
      expect([ ...new Uint8Array(customSections[1].data.buffer, customSections[1].data.byteOffset, customSections[1].data.byteLength) ]).to.eql([ 5, 6, 7, 8 ]);
    })
    it('should ensure __stack_pointer global[0] is exported for stack switching', async function() {
      const path = absolute(`../../zigar-runtime/test/features/wasm-samples/read-file.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const newBinary = stripUnused(binary);
      const mod = new WebAssembly.Module(new Uint8Array(newBinary.buffer, newBinary.byteOffset, newBinary.byteLength));
      const exports = WebAssembly.Module.exports(mod);
      expect(exports).to.deep.include({ name: '__stack_pointer', kind: 'global' });
      // Calling ensureStackPointerExport on an unstripped binary should also export __stack_pointer
      const debugBinary = ensureStackPointerExport(binary);
      const debugMod = new WebAssembly.Module(new Uint8Array(debugBinary.buffer, debugBinary.byteOffset, debugBinary.byteLength));
      expect(WebAssembly.Module.exports(debugMod)).to.deep.include({ name: '__stack_pointer', kind: 'global' });
      // Calling ensureStackPointerExport a second time should be a no-op
      expect(ensureStackPointerExport(debugBinary)).to.equal(debugBinary);
    })
    it('should export __stack_pointer even if global[0] is exported under another name, and skip if global is imported', function() {
      // Module where global[0] is mutable i32 and exported as "sp_alias"
      const aliasWasm = new Uint8Array([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x06, 0x07, 0x01, 0x7f, 0x01, 0x41, 0x80, 0x08, 0x0b,
        0x07, 0x0c, 0x01, 0x08, 0x73, 0x70, 0x5f, 0x61, 0x6c, 0x69, 0x61, 0x73, 0x03, 0x00,
      ]);
      const patched = ensureStackPointerExport(new DataView(aliasWasm.buffer));
      const mod = new WebAssembly.Module(new Uint8Array(patched.buffer, patched.byteOffset, patched.byteLength));
      expect(WebAssembly.Module.exports(mod)).to.deep.include({ name: '__stack_pointer', kind: 'global' });

      // Module where global[0] is imported
      const importedGlobalWasm = new Uint8Array([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x02, 0x67, 0x30, 0x03, 0x7f, 0x01,
        0x06, 0x07, 0x01, 0x7f, 0x01, 0x41, 0x80, 0x08, 0x0b,
        0x07, 0x01, 0x00,
      ]);
      const dvImported = new DataView(importedGlobalWasm.buffer);
      expect(ensureStackPointerExport(dvImported)).to.equal(dvImported);

      // Module where global[0] is mutable i64 (wasm64 __stack_pointer, valtype 0x7e)
      const i64SpWasm = new Uint8Array([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x06, 0x07, 0x01, 0x7e, 0x01, 0x42, 0x80, 0x08, 0x0b,
        0x07, 0x01, 0x00,
      ]);
      const patchedI64 = ensureStackPointerExport(new DataView(i64SpWasm.buffer));
      const modI64 = new WebAssembly.Module(new Uint8Array(patchedI64.buffer, patchedI64.byteOffset, patchedI64.byteLength));
      expect(WebAssembly.Module.exports(modI64)).to.deep.include({ name: '__stack_pointer', kind: 'global' });
    })
    it('should strip i64.const getFactoryThunk and factory function with dynamic active element offset', function() {
      // Type 0: () -> i64, Type 1: () -> void
      // Functions:
      //   0 (factoryFn, type 1): calls imported _createBool (wait: internal helper fn 1)
      //   1 (unusedFactoryHelper, type 1): nop; end
      //   2 (getFactoryThunk, type 0, exported): i64.const 5; end  (points to table slot 5 -> segment offset 5 + idx 0 = func 0)
      //   3 (runThunk, type 1, exported): nop; end
      //   4 (keptCallback, type 1, in table slot 6): nop; end
      const typeData = new DataView(new Uint8Array([
        0x02,
        0x60, 0x00, 0x01, 0x7e,
        0x60, 0x00, 0x00,
      ]).buffer);
      const tableData = new DataView(new Uint8Array([
        0x01, 0x70, 0x04, 0x10, // 1 funcref table64, min=16
      ]).buffer);
      const globalData = new DataView(new Uint8Array([
        0x01, 0x7e, 0x01, 0x42, 0x80, 0x80, 0x04, 0x0b, // mutable i64 __stack_pointer
      ]).buffer);
      const fnFactory = new DataView(new Uint8Array([ 0x00, 0x10, 0x01, 0x0b ]).buffer); // calls func 1
      const fnHelper = new DataView(new Uint8Array([ 0x00, 0x0b ]).buffer);
      const fnGetFactory = new DataView(new Uint8Array([ 0x00, 0x42, 0x05, 0x0b ]).buffer); // i64.const 5; end
      const fnRunThunk = new DataView(new Uint8Array([ 0x00, 0x0b ]).buffer);
      const fnKeptCb = new DataView(new Uint8Array([ 0x00, 0x0b ]).buffer);
      const mod = {
        size: 256,
        sections: [
          { type: SectionType.Type, data: typeData },
          { type: SectionType.Function, types: [ 1, 1, 0, 1, 1 ] },
          { type: SectionType.Table, data: tableData },
          { type: SectionType.Global, data: globalData },
          {
            type: SectionType.Export,
            exports: [
              { name: 'getFactoryThunk', type: ObjectType.Function, index: 2 },
              { name: 'runThunk', type: ObjectType.Function, index: 3 },
            ],
          },
          {
            type: SectionType.Element,
            segments: [
              {
                type: 0,
                expr: new DataView(new Uint8Array([ 0x42, 0x05, 0x0b ]).buffer), // i64.const 5; end
                indices: [ 0, 4 ],
              },
            ],
          },
          {
            type: SectionType.Code,
            functions: [ fnFactory, fnHelper, fnGetFactory, fnRunThunk, fnKeptCb ],
          },
        ],
      };
      const dv = repackBinary(mod);
      const stripped = stripUnused(dv);
      const parsed = parseBinary(stripped);
      const codeSec = parsed.sections.find(s => s.type === SectionType.Code);
      // Only runThunk and keptCallback should remain (factoryFn, unusedFactoryHelper, getFactoryThunk all stripped!)
      expect(codeSec.functions).to.have.lengthOf(2);
      const compiled = new WebAssembly.Module(new Uint8Array(stripped.buffer, stripped.byteOffset, stripped.byteLength));
      const exportNames = WebAssembly.Module.exports(compiled).map(e => e.name);
      expect(exportNames).to.include('runThunk');
      expect(exportNames).to.include('__stack_pointer');
      expect(exportNames).to.not.include('getFactoryThunk');
    })
  })
  describe('parseNames', function() {
    it('should extract module name from name section', async function() {
      const path = absolute(`./wasm-samples/module-name.wasm`);
      const content = await readFile(path);
      const binary = new DataView(content.buffer);
      const { sections } = parseBinary(binary);
      const nameSection = sections.find(s => s.name === 'name');
      const { moduleName } = parseNames(nameSection);
      expect(moduleName).to.equal('my_module');
    })
  })
  describe('repackNames', function() {
    it('should create data for name section', function() {
      const moduleName = 'Hello';
      const functionNames = [
        'func1',
        'func2',
        'func3',
      ];
      const localNames = [
        [
          { index: 0, name: 'var1' },
          { index: 1, name: 'var2' },
          { index: 2, name: 'var3' },
        ],
        [
          { index: 0, name: 'var1' },
          { index: 1, name: 'var2' },
          { index: 2, name: 'var3' },
        ],
        [
          { index: 0, name: 'var1' },
          { index: 1, name: 'var2' },
          { index: 2, name: 'var3' },
        ],
      ];
      const size = 1024;
      const data = repackNames({ moduleName, functionNames, localNames, size });
      const parsed = parseNames({ data });
      expect(parsed.moduleName).to.equal(moduleName);
      expect(parsed.functionNames).to.eql(functionNames);
      expect(parsed.localNames).to.eql(localNames);
    })
  })
  describe('extractLimits and memory64/GC decoding', function() {
    it('should populate memoryInitial/tableInitial strictly from imports and report defined/64-bit limits separately', function() {
      // 1. Module with internally defined memory64 (min=0x10001, max=0x20000) and table64 (min=16)
      //    flags: 0x05 = has_max (0x01) | is_64 (0x04), 0x04 = is_64
      const defined64Module = {
        size: 128,
        sections: [
          {
            type: SectionType.Table,
            // raw SectionType.Table bytes: 1 table, funcref 0x70, flags 0x04, min 16
            data: new DataView(new Uint8Array([ 0x01, 0x70, 0x04, 0x10 ]).buffer),
          },
          {
            type: SectionType.Memory,
            // raw SectionType.Memory bytes: 1 memory, flags 0x05, min 0x10001 (0x81,0x80,0x04), max 0x20000 (0x80,0x80,0x08)
            data: new DataView(new Uint8Array([ 0x01, 0x05, 0x81, 0x80, 0x04, 0x80, 0x80, 0x08 ]).buffer),
          },
        ],
      };
      const dvDefined = repackBinary(defined64Module);
      const limitsDefined = extractLimits(dvDefined);
      expect(limitsDefined.memoryInitial).to.be.undefined;
      expect(limitsDefined.memoryMax).to.be.undefined;
      expect(limitsDefined.tableInitial).to.be.undefined;
      expect(limitsDefined.definedMemoryInitial).to.equal(0x10001);
      expect(limitsDefined.definedMemoryMax).to.equal(0x20000);
      expect(limitsDefined.memory64).to.be.true;
      expect(limitsDefined.table64).to.be.true;

      // 2. Module with imported memory64 (> 4GB pages: min=0x1_0000_0000 -> wait, use 0x100000 pages = 64GB) and imported table64
      const imported64Module = {
        size: 256,
        sections: [
          {
            type: SectionType.Import,
            imports: [
              {
                module: 'env',
                name: 'memory',
                type: ObjectType.Memory,
                limits: { flags: 0x07, min: 0x100000, max: 0x200000, shared: true, is64: true },
              },
              {
                module: 'env',
                name: '__indirect_function_table',
                type: ObjectType.Table,
                reftype: 0x70,
                limits: { flags: 0x04, min: 32, max: undefined, shared: undefined, is64: true },
              },
            ],
          },
        ],
      };
      const dvImported = repackBinary(imported64Module);
      const reparsed = parseBinary(dvImported);
      expect(reparsed.sections[0].imports[0].limits.min).to.equal(0x100000);
      expect(reparsed.sections[0].imports[0].limits.max).to.equal(0x200000);
      expect(reparsed.sections[0].imports[0].limits.is64).to.be.true;
      expect(reparsed.sections[0].imports[1].limits.is64).to.be.true;
      const limitsImported = extractLimits(dvImported);
      expect(limitsImported.memoryInitial).to.equal(0x100000);
      expect(limitsImported.memoryMax).to.equal(0x200000);
      expect(limitsImported.tableInitial).to.equal(32);
      expect(limitsImported.definedMemoryInitial).to.be.undefined;
      expect(limitsImported.memory64).to.be.true;
      expect(limitsImported.table64).to.be.true;

      // 3. 32-bit limits expose is64: false
      const imported32Module = {
        size: 128,
        sections: [
          {
            type: SectionType.Import,
            imports: [
              {
                module: 'env',
                name: 'memory',
                type: ObjectType.Memory,
                limits: { flags: 0x01, min: 2, max: 16 },
              },
            ],
          },
        ],
      };
      const dv32 = repackBinary(imported32Module);
      const reparsed32 = parseBinary(dv32);
      expect(reparsed32.sections[0].imports[0].limits.is64).to.be.false;
    })
    it('should decode, strip, and export __stack_pointer on real compiled wasm64-wasi binaries', async function() {
      const simpleSrc = absolute('./zig-samples/basic/simple.zig');
      const stOpts = { optimize: 'ReleaseSmall', arch: 'wasm64', platform: 'wasi', isWASM: true, memory64: true };
      const stRes = await compile(simpleSrc, getModuleCachePath(simpleSrc, stOpts), stOpts);
      const stBytes = await readFile(stRes.outputPath);
      const stDV = new DataView(stBytes.buffer, stBytes.byteOffset, stBytes.byteLength);
      const stLimits = extractLimits(stDV);
      expect(stLimits.memory64).to.be.true;
      expect(stLimits.table64).to.be.true;
      expect(stLimits.definedMemoryMax).to.equal(65536);
      expect(typeof stLimits.tableInitial).to.equal('number');
      const stStripped = stripUnused(stDV);
      expect(stStripped.byteLength).to.be.below(stDV.byteLength);
      const stMod = await WebAssembly.compile(new Uint8Array(stStripped.buffer, stStripped.byteOffset, stStripped.byteLength));
      const stExports = WebAssembly.Module.exports(stMod).map(e => e.name);
      expect(stExports).to.include('__stack_pointer');
      expect(stExports).to.not.include('getFactoryThunk');
      const stUnstripped = ensureStackPointerExport(stDV);
      const stUnstrippedMod = await WebAssembly.compile(new Uint8Array(stUnstripped.buffer, stUnstripped.byteOffset, stUnstripped.byteLength));
      expect(WebAssembly.Module.exports(stUnstrippedMod).map(e => e.name)).to.include('__stack_pointer');

      const atomicSrc = absolute('./zig-samples/basic/atomic.zig');
      const mtOpts = { optimize: 'ReleaseSmall', arch: 'wasm64', platform: 'wasi', isWASM: true, memory64: true, multithreaded: true };
      const mtRes = await compile(atomicSrc, getModuleCachePath(atomicSrc, mtOpts), mtOpts);
      const mtBytes = await readFile(mtRes.outputPath);
      const mtDV = new DataView(mtBytes.buffer, mtBytes.byteOffset, mtBytes.byteLength);
      const mtLimits = extractLimits(mtDV);
      expect(mtLimits.memory64).to.be.true;
      expect(mtLimits.table64).to.be.true;
      expect(mtLimits.memoryMax).to.equal(1024);
      const mtStripped = stripUnused(mtDV);
      const mtMod = await WebAssembly.compile(new Uint8Array(mtStripped.buffer, mtStripped.byteOffset, mtStripped.byteLength));
      expect(WebAssembly.Module.exports(mtMod).map(e => e.name)).to.include('__stack_pointer');
    })
    it('should decode and repack call_ref (0x14), return_call_ref (0x15), and >4GB memory64 memarg offsets', function() {
      // Function body:
      // 0 locals
      // i64.const 0; i32.load align=2 offset=0x1_0000_0004 (LEB128: 0x84, 0x80, 0x80, 0x80, 0x10); drop
      // i32.load align=2 offset=16 (small offset stays Number); drop
      // call_ref type_idx=3
      // return_call_ref type_idx=5
      // atomic i32.atomic.load (0xFE 0x10) align=2 offset=0x2_0000_0000 (0x80, 0x80, 0x80, 0x80, 0x20)
      // end
      const rawBody = new Uint8Array([
        0x00, // 0 locals
        0x42, 0x00,
        0x28, 0x02, 0x84, 0x80, 0x80, 0x80, 0x10,
        0x1a,
        0x41, 0x00,
        0x28, 0x02, 0x10,
        0x1a,
        0x14, 0x03,
        0x15, 0x05,
        0xfe, 0x10, 0x02, 0x80, 0x80, 0x80, 0x80, 0x20,
        0x0b,
      ]);
      const dv = new DataView(rawBody.buffer);
      const parsed = parseFunction(dv);
      expect(parsed.instructions[1]).to.eql({ opcode: 0x28, operand: [ 2, 0x100000004n ] });
      expect(parsed.instructions[4]).to.eql({ opcode: 0x28, operand: [ 2, 16 ] });
      expect(parsed.instructions[6]).to.eql({ opcode: 0x14, operand: 3 });
      expect(parsed.instructions[7]).to.eql({ opcode: 0x15, operand: 5 });
      expect(parsed.instructions[8]).to.eql({ opcode: 0xfe, operand: [ 0x10, 2, 0x200000000n ] });

      const repacked = repackFunction(parsed);
      expect([ ...new Uint8Array(repacked.buffer, repacked.byteOffset, repacked.byteLength) ])
        .to.eql([ ...rawBody ]);
    })
  })
  describe('analyzeJspiSyncFunctions', function() {
    it('should statically classify pure/sync table functions vs direct and indirect suspending callers', function() {
      // Imports (indices 0..4):
      //   0: wasi_snapshot_preview1.clock_time_get (type 0) -> pure sync
      //   1: env._createBool                       (type 0) -> pure sync
      //   2: wasi_snapshot_preview1.fd_read        (type 0) -> SUSPENDING
      //   3: env._handleJscall                     (type 1) -> SUSPENDING
      //   4: env._futexWaitAsync                   (type 1) -> SUSPENDING
      //
      // Internal functions (indices 5..12):
      //   5 (slot 1, type 2): pure leaf -> SYNC
      //   6 (slot 2, type 2): calls clock_time_get (0) and _createBool (1) -> SYNC
      //   7 (slot 3, type 2): calls fd_read (2) -> SUSPENDING
      //   8 (slot 4, type 2): call_indirect type 3 (only func 11 has type 3, and func 11 is pure) -> SYNC
      //   9 (slot 5, type 2): call_indirect type 4 (func 12 has type 4 and calls _handleJscall (3)) -> SUSPENDING
      //  10 (slot 6, type 2): calls _futexWaitAsync (4) -> SUSPENDING
      //  11 (slot 7, type 3): pure callback target -> SYNC
      //  12 (slot 8, type 4): js-fn thunk calling _handleJscall (3) -> SUSPENDING
      //  13 (exported as runThunk, type 0): call_indirect type 2 -> overhead has no direct suspending calls
      const fnPure = new DataView(new Uint8Array([ 0x00, 0x0b ]).buffer);
      const fnSyncImports = new DataView(new Uint8Array([ 0x00, 0x10, 0x00, 0x10, 0x01, 0x0b ]).buffer);
      const fnFdRead = new DataView(new Uint8Array([ 0x00, 0x10, 0x02, 0x0b ]).buffer);
      const fnIndirectSync = new DataView(new Uint8Array([ 0x00, 0x41, 0x07, 0x11, 0x03, 0x00, 0x0b ]).buffer);
      const fnIndirectAsync = new DataView(new Uint8Array([ 0x00, 0x41, 0x08, 0x11, 0x04, 0x00, 0x0b ]).buffer);
      const fnFutexAsync = new DataView(new Uint8Array([ 0x00, 0x10, 0x04, 0x0b ]).buffer);
      const fnPureTarget = new DataView(new Uint8Array([ 0x00, 0x0b ]).buffer);
      const fnJsThunk = new DataView(new Uint8Array([ 0x00, 0x10, 0x03, 0x0b ]).buffer);
      const fnRunThunk = new DataView(new Uint8Array([ 0x00, 0x41, 0x01, 0x11, 0x02, 0x00, 0x0b ]).buffer);

      const mod = {
        size: 512,
        sections: [
          {
            type: SectionType.Import,
            imports: [
              { module: 'wasi_snapshot_preview1', name: 'clock_time_get', type: ObjectType.Function, index: 0 },
              { module: 'env', name: '_createBool', type: ObjectType.Function, index: 0 },
              { module: 'wasi_snapshot_preview1', name: 'fd_read', type: ObjectType.Function, index: 0 },
              { module: 'env', name: '_handleJscall', type: ObjectType.Function, index: 1 },
              { module: 'env', name: '_futexWaitAsync', type: ObjectType.Function, index: 1 },
            ],
          },
          {
            type: SectionType.Function,
            types: [ 2, 2, 2, 2, 2, 2, 3, 4, 0 ],
          },
          {
            type: SectionType.Export,
            exports: [
              { name: 'runThunk', type: ObjectType.Function, index: 13 },
            ],
          },
          {
            type: SectionType.Element,
            segments: [
              {
                type: 0,
                expr: new DataView(new Uint8Array([ 0x41, 0x01, 0x0b ]).buffer), // offset = 1
                indices: [ 5, 6, 7, 8, 9, 10, 11, 12 ],
              },
            ],
          },
          {
            type: SectionType.Code,
            functions: [
              fnPure,
              fnSyncImports,
              fnFdRead,
              fnIndirectSync,
              fnIndirectAsync,
              fnFutexAsync,
              fnPureTarget,
              fnJsThunk,
              fnRunThunk,
            ],
          },
        ],
      };

      const dv = repackBinary(mod);
      const syncSlots = analyzeJspiSyncFunctions(dv);
      expect(syncSlots).to.eql([ 1, 2, 4, 7 ]);

      // If runThunk itself directly calls a suspending helper (e.g. fflush -> fd_read), no slot is sync
      mod.sections[4].functions[8] = new DataView(new Uint8Array([
        0x00, 0x41, 0x01, 0x11, 0x02, 0x00, 0x10, 0x07, 0x0b,
      ]).buffer);
      const dvWithFflush = repackBinary(mod);
      expect(analyzeJspiSyncFunctions(dvWithFflush)).to.eql([]);
    })
  })
})

function absolute(relPath) {
  return fileURLToPath(new URL(relPath, import.meta.url));
}
