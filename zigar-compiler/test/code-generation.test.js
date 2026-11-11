import { expect } from 'chai';

import { MemberType, StructureType } from '../../zigar-runtime/src/constants.js';
import { MEMORY, SLOTS } from '../../zigar-runtime/src/symbols.js';
import { generateCode } from '../src/code-generation.js';

describe('Code generation', function() {
  const settings = {
    littleEndian: true,
    runtimeSafety: true,
    libc: false,
  };
  describe('generateCode', function() {
    const params = {
      declareFeatures: true,
      binarySource: '"/somewhere.wasm"',
    };
    it('should generate code for defining types', function() {
      const structure = {
        constructor: null,
        type: StructureType.Primitive,
        name: 'i32',
        signature: 0xdead_beefn,
        byteSize: 4,
        isConst: false,
        hasPointer: false,
        instance: {
          members: [
            {
              type: MemberType.Int,
              bitOffset: 0,
              bitSize: 32,
              byteSize: 4,
            }
          ],
          methods: [],
          template: null,
        },
        static: {
          members: [],
          methods: [],
          template: null,
        },
      };
      const def = { structures: [ structure ], settings };
      const { code } = generateCode(def, { ...params, binarySource: null });
      expect(code).to.contain('deadbeef');
      expect(code).to.contain('i32');
      expect(code).to.not.contain('const source =');
    })
    it('should generate standalone module loader', function() {
      const structure = {
        constructor: null,
        type: StructureType.Primitive,
        name: 'i32',
        signature: 0xdead_beefn,
        byteSize: 4,
        isConst: false,
        hasPointer: false,
        instance: {
          members: [
            {
              type: MemberType.Int,
              bitOffset: 0,
              bitSize: 32,
              byteSize: 4,
            }
          ],
          methods: [],
          template: null,
        },
        static: {
          members: [],
          methods: [],
          template: null,
        },
      };
      const def = { structures: [ structure ], settings };
      const standaloneLoader = {
        type: 'esm',
        addonDir: '../lib/node-zigar-addon',
        moduleDir: '../lib/module.zigar',
      };
      const { code } = generateCode(def, { ...params, standaloneLoader, binarySource: null });
      expect(code).to.contain('const moduleName');
      expect(code).to.contain('const addonName');
    })
    it('should generate CommonJS standalone module loader', function() {
      const structure = {
        constructor: null,
        type: StructureType.Primitive,
        name: 'i32',
        signature: 0xdead_beefn,
        byteSize: 4,
        isConst: false,
        hasPointer: false,
        instance: {
          members: [
            {
              type: MemberType.Int,
              bitOffset: 0,
              bitSize: 32,
              byteSize: 4,
            }
          ],
          methods: [],
          template: null,
        },
        static: {
          members: [],
          methods: [],
          template: null,
        },
      };
      const def = { structures: [ structure ], settings };
      const standaloneLoader = {
        type: 'cjs',
        addonDir: '../lib/node-zigar-addon',
        moduleDir: '../lib/module.zigar',
      };
      const { code } = generateCode(def, { ...params, standaloneLoader, binarySource: null });
      expect(code).to.contain('const moduleName');
      expect(code).to.contain('const addonName');
    })
    it('should omit exports when omitExports is true', function() {
      const structStructure = {
        constructor: null,
        type: StructureType.Struct,
        name: "struct {}",
        byteSize: 4,
        hasPointer: true,
        instance: {
          members: [
            {
              type: MemberType.Int,
              name: "number",
              bitOffset: 0,
              bitSize: 32,
              byteSize: 4,
            },
          ],
          methods: [],
          template: {
            [SLOTS]: {},
          },
        },
        static: {
          members: [],
          methods: [],
          template: null,
        },
      };
      const structure = {
        constructor: null,
        type: StructureType.Struct,
        name: "package",
        byteSize: 0,
        hasPointer: false,
        instance: {
          members: [],
          methods: [],
          template: null,
        },
        static: {
          members: [
            {
              type: MemberType.Type,
              name: 'Hello',
              structure: structStructure,
            }
          ],
          methods: [],
          template: null,
        },
      };
      const def = { structures: [ structStructure, structure ], settings };
      const { code, exports } = generateCode(def, { omitExports: true, ...params });
      expect(code).to.not.contain('export {');
      expect(exports).to.contain('__zigar');
    })
    it('should break initializer into multiple lines when the number of structures is large', function() {
      const structures = [];
      for (let bitSize = 2; bitSize <= 64; bitSize++) {
        structures.push({
          constructor: null,
          type: StructureType.Primitive,
          name: `i${bitSize}`,
          byteSize: 8,
          isConst: false,
          hasPointer: false,
          instance: {
            members: [
              {
                type: MemberType.Int,
                bitOffset: 0,
                bitSize,
                byteSize: 8,
              }
            ],
            methods: [],
            template: null,
          },
          static: {
            members: [],
            methods: [],
            template: null,
          },
        });
      }
      const def = { structures, settings };
      const { code } = generateCode(def, params);
    })
    it('should include settings for environment', function() {
      const structure = {
        constructor: null,
        type: StructureType.Primitive,
        name: "f32",
        byteSize: 4,
        isConst: false,
        hasPointer: false,
        instance: {
          members: [
            {
              type: MemberType.Float,
              bitOffset: 0,
              bitSize: 32,
              byteSize: 4,
            }
          ],
          methods: [],
          template: null,
        },
        static: {
          members: [],
          methods: [],
          template: null,
        },
      };
      const moduleOptions = { addonPath: '/tmp/somewhere' };
      const def = { structures: [ structure ], settings };
      const { code } = generateCode(def, { ...params, moduleOptions });
      expect(code).to.contain('addonPath');
      expect(code).to.contain('/tmp/somewhere');
    })
    it('should include environment variables', function() {
      const structure = {
        constructor: null,
        type: StructureType.Primitive,
        name: "f32",
        byteSize: 4,
        isConst: false,
        hasPointer: false,
        instance: {
          members: [
            {
              type: MemberType.Float,
              bitOffset: 0,
              bitSize: 32,
              byteSize: 4,
            }
          ],
          methods: [],
          template: null,
        },
        static: {
          members: [],
          methods: [],
          template: null,
        },
      };
      const def = { structures: [ structure ], settings };
      const envVariables = { ADDON_PATH: '/tmp/somewhere' };
      const { code } = generateCode(def, { ...params, envVariables });
      expect(code).to.contain('process.env.');
      expect(code).to.contain('ADDON_PATH');
      expect(code).to.contain('/tmp/somewhere');
    })
    it('should emit BigInt handle literals with trailing n suffix and memory64 settings', function() {
      const dv64 = new DataView(new ArrayBuffer(8));
      dv64.handle = 0x1_0000_1040n;
      const dv32 = new DataView(new ArrayBuffer(4));
      dv32.handle = 0x1040;
      const structure = {
        constructor: null,
        type: StructureType.Struct,
        name: 'Root64',
        byteSize: 0,
        instance: { members: [], template: { [MEMORY]: dv32 } },
        static: { members: [], template: { [MEMORY]: dv64 } },
      };
      const def64 = { structures: [ structure ], settings: { ...settings, memory64: true } };
      const moduleOptions = { memory64: true, table64: true, tableInitial: 128, multithreaded: false };
      const { code: code64 } = generateCode(def64, { ...params, moduleOptions });
      expect(code64).to.contain(`handle: ${0x1_0000_1040n}n,`);
      expect(code64).to.contain(`handle: ${0x1040},`);
      expect(code64).to.contain('memory64: true,');
      expect(code64).to.contain('"memory64":true');
      expect(code64).to.contain('"table64":true');

      // Default wasm32 omits memory64 from settings
      const def32 = { structures: [ structure ], settings: { ...settings, memory64: false } };
      const { code: code32 } = generateCode(def32, { ...params, moduleOptions: { multithreaded: false } });
      expect(code32).to.not.contain('memory64:');
    })
  })
})
