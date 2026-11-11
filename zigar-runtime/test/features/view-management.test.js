import { expect } from 'chai';
import { MemberType, StructureFlag, StructureType } from '../../src/constants.js';
import { defineEnvironment } from '../../src/environment.js';
import '../../src/mixins.js';
import { FALLBACK, LENGTH, MEMORY, RESTORE, SHAPE, TYPED_ARRAY, ZIG } from '../../src/symbols.js';
import { createView, defineProperties, usize } from '../../src/utils.js';

const Env = defineEnvironment();

describe('Feature: view-management', function() {
  describe('extractView', function() {
    it('should return a DataView when given an ArrayBuffer', function() {
      const structure = {
        type: StructureType.Array,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 8
      };
      const arg = new ArrayBuffer(8);
      const env = new Env();
      const dv = env.extractView(structure, arg);
      expect(dv).to.be.instanceOf(DataView);
    })
    it('should return a DataView when given an DataView', function() {
      const structure = {
        type: StructureType.Array,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 8
      };
      const arg = new DataView(new ArrayBuffer(8));
      const env = new Env();
      const dv = env.extractView(structure, arg);
      expect(dv).to.be.instanceOf(DataView);
    })
    it('should return a DataView when given an DataView with length that is multiple of given size', function() {
      const structure = {
        type: StructureType.Slice,
        name: 'Test',
        byteSize: 8
      };
      const arg = new DataView(new ArrayBuffer(64));
      const env = new Env();
      const dv = env.extractView(structure, arg);
      expect(dv).to.be.instanceOf(DataView);
    })
    it('should return a DataView when given an empty DataView', function() {
      const structure = {
        type: StructureType.Slice,
        name: 'Test',
        byteSize: 8
      };
      const arg = new DataView(new ArrayBuffer(0));
      const env = new Env();
      const dv = env.extractView(structure, arg);
      expect(dv).to.be.instanceOf(DataView);
    })
    it('should throw when argument is not a data view or buffer', function() {
      const structure = {
        type: StructureType.Slice,
        name: 'Test',
        byteSize: 8
      };
      const arg = {};
      const env = new Env();
      expect(() => env.extractView(structure, arg)).to.throw(TypeError)
        .with.property('message').that.contains('8');
    })
    it('should return undefined when argument is not a data view or buffer and required is false', function() {
      const structure = {
        type: StructureType.Slice,
        name: 'Test',
        byteSize: 8
      };
      const arg = {};
      const env = new Env();
      const dv = env.extractView(structure, arg, null);
      expect(dv).to.be.undefined;
    })
    it('should throw when there is a size mismatch', function() {
      const structure1 = {
        type: StructureType.Array,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 17
      };
      const structure2 = {
        type: StructureType.Slice,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 3
      };
      const env = new Env();
      const arg = new DataView(new ArrayBuffer(8));
      expect(() => env.extractView(structure1, arg)).to.throw(TypeError)
        .with.property('message').that.contains('17');
      expect(() => env.extractView(structure2, arg)).to.throw(TypeError)
        .with.property('message').that.contains('3');
    })
    it('should accept compatible TypedArray', function() {
      const constructor = function() {};
      constructor[TYPED_ARRAY] = Uint32Array;
      const structure = {
        type: StructureType.Slice,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 3,
        constructor,
      };
      const env = new Env();
      const ta1 = new Uint32Array([ 1, 2, 3 ]);
      const ta2 = new Int32Array([ 1, 2, 3 ]);
      const dv1 = env.extractView(structure, ta1, null);
      const dv2 = env.extractView(structure, ta2, null);
      expect(dv1).to.be.an.instanceOf(DataView);
      expect(dv2).to.be.undefined;
    })
    it('should return memory of compatible array', function() {
      const elementConstructor = function() {};
      const structure = {
        type: StructureType.Slice,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 2,
        instance: {
          members: [
            {
              type: MemberType.Object,
              bitOffset: 0,
              byteSize: 2,
              structure: { constructor: elementConstructor }
            }
          ]
        },
        constructor: function() {},
      };
      const arrayConstructor = function() {};
      arrayConstructor.child = elementConstructor;
      const array = new arrayConstructor();
      array[MEMORY] = new DataView(new ArrayBuffer(6));
      array.length = 3;
      const env = new Env();
      const dv = env.extractView(structure, array);
      expect(dv).to.be.an.instanceOf(DataView);
    })
    it('should return memory of compatible slice', function() {
      const elementConstructor = function() {};
      const structure = {
        type: StructureType.Array,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 6,
        length: 3,
        instance: {
          members: [
            {
              type: MemberType.Object,
              bitOffset: 0,
              byteSize: 2,
              structure: { constructor: elementConstructor }
            }
          ]
        },
        constructor: function() {},
      };
      const arrayConstructor = function() {};
      arrayConstructor.child = elementConstructor;
      const array = new arrayConstructor();
      array[MEMORY] = new DataView(new ArrayBuffer(6));
      array.length = 3;
      const env = new Env();
      const dv = env.extractView(structure, array);
      expect(dv).to.equal(array[MEMORY]);
    })
    it('should fail when slice length does not match size of array', function() {
      const elementConstructor = function() {};
      const structure = {
        type: StructureType.Array,
        flags: StructureFlag.HasProxy,
        name: 'Test',
        byteSize: 6,
        length: 3,
        instance: {
          members: [
            {
              type: MemberType.Object,
              bitOffset: 0,
              byteSize: 2,
              structure: { constructor: elementConstructor }
            }
          ]
        },
        constructor: function() {},
      };
      const arrayConstructor = function() {};
      arrayConstructor.child = elementConstructor;
      const array = new arrayConstructor();
      array[MEMORY] = new DataView(new ArrayBuffer(8));
      array.length = 4;
      const env = new Env();
      expect(() => dv = env.extractView(structure, array)).to.throw(TypeError);
    })
    it('should return memory of compatible object', function() {
      const elementConstructor = function() {};
      const structure = {
        type: StructureType.Slice,
        name: 'Test',
        byteSize: 2,
        instance: {
          members: [
            {
              type: MemberType.Object,
              bitOffset: 0,
              byteSize: 2,
              structure: { constructor: elementConstructor }
            }
          ]
        },
        constructor: function() {},
      };
      const object = new elementConstructor();
      object[MEMORY] = new DataView(new ArrayBuffer(2));
      const env = new Env();
      const dv = env.extractView(structure, object);
      expect(dv).to.equal(object[MEMORY]);
    })
  })
  describe('obtainView', function() {
    it('should obtain the same view object for the same offset and length', function() {
      const env = new Env();
      const buffer = new ArrayBuffer(48);
      const dv1 = env.obtainView(buffer, 4, 8);
      expect(dv1.byteOffset).to.equal(4);
      expect(dv1.byteLength).to.equal(8);
      const dv2 = env.obtainView(buffer, 4, 8);
      expect(dv2).to.equal(dv1);
    })
    it('should obtain the different view objects when cache = false', function() {
      const env = new Env();
      const buffer = new ArrayBuffer(48);
      const dv1 = env.obtainView(buffer, 4, 8, false);
      const dv2 = env.obtainView(buffer, 4, 8, false);
      expect(dv2).to.not.equal(dv1);
    })
    it('should be able to keep track of multiple views', function() {
      const env = new Env();
      const buffer = new ArrayBuffer(48);
      const dv1 = env.obtainView(buffer, 4, 8);
      expect(dv1.byteOffset).to.equal(4);
      const dv2 = env.obtainView(buffer, 8, 16);
      expect(dv2.byteOffset).to.equal(8);
      const dv3 = env.obtainView(buffer, 8, 16);
      expect(dv3).to.equal(dv2);
      const dv4 = env.obtainView(buffer, 4, 8);
      expect(dv4).to.equal(dv1);
    })
    if (process.env.TARGET === 'node') {
      it('should attach fallback handler when buffer requires it', function() {
        const env = new Env();
        let called = false;
        env.moveExternBytes = function(jsDV, address, to) {
          expect(to).to.be.false;
          called = true;
          for (let i = 0; i < jsDV.byteLength; i++) {
            jsDV.setUint8(i, 0xAA);
          }
        };
        const address = usize(0x1000);
        const len = 32;
        const buffer = new ArrayBuffer(len);
        buffer[ZIG] = { address, len };
        buffer[FALLBACK] = address;
        const dv = env.obtainView(buffer, 0, 16);
        expect(dv[FALLBACK]).to.be.a('function');
        for (let i = 0; i < dv.byteLength; i++) {
            dv.setUint8(i, 0xBB);
        }
        dv[FALLBACK](false);
        expect(called).to.be.true;
        expect(dv.getUint8(0)).to.equal(0xAA);
        dv.setUint8(0, 7);
        dv.setUint8(4, 13);
        dv.setUint8(5, 17);
        dv[FALLBACK](false, 1, 4);
        expect(dv.getUint8(0)).to.equal(7);
        expect(dv.getUint8(5)).to.equal(17);
        expect(dv.getUint8(4)).to.equal(0xAA);
      })     
    }

  })
  describe('registerView', function() {
    it('should register views with their underlying buffer', function() {
      const env = new Env();
      const buffer = new ArrayBuffer(48);
      const dv1 = new DataView(buffer, 4, 8);
      env.registerView(dv1);
      expect(env.obtainView(buffer, 4, 8)).to.equal(dv1);
      const dv2 = new DataView(buffer, 8, 16);
      env.registerView(dv2);
      expect(env.obtainView(buffer, 4, 8)).to.equal(dv1);
      expect(env.obtainView(buffer, 8, 16)).to.equal(dv2);
      const dv3 = new DataView(buffer, 8, 32);
      env.registerView(dv3);
      expect(env.obtainView(buffer, 8, 32)).to.equal(dv3);
      const dv4 = new DataView(buffer);
      env.registerView(dv4);
      expect(env.obtainView(buffer, 0, 48)).to.equal(dv4);
      expect(env.obtainView(buffer, 4, 8)).to.equal(dv1);
      expect(env.obtainView(buffer, 8, 16)).to.equal(dv2);
      expect(env.obtainView(buffer, 8, 32)).to.equal(dv3);
    })
  })
  describe('assignView', function() {
    it('should assume element size of one when structure has no shape', function() {
      const env = new Env();
      const structure = {
        type: StructureType.Slice,
        name: 'Opaque',
        byteSize: undefined,
      };
      const target = {
      };
      defineProperties(target, {
        [MEMORY]: { value: new DataView(new ArrayBuffer(16)) },
        [RESTORE]: { value: function() { return this[MEMORY] } },
        length: { value: 16 },
      });
      const dv = new DataView(new ArrayBuffer(16));
      env.assignView(target, dv, structure, false, null);
    })
    it('should copy data when target is in Zig memory', function() {
      const env = new Env();
      const structure = {
        type: StructureType.Slice,
        name: 'Opaque',
        byteSize: undefined,
      };
      const target = {
      };
      defineProperties(target, {
        [MEMORY]: { value: null },
        [RESTORE]: { value: function() { return this[MEMORY] } },
        [SHAPE]: {
          value(dv, length, allocator) {
            if (!dv) {
              dv = env.allocateMemory(length * 1, 1, allocator);
            }
            this[MEMORY] = dv;
            this[LENGTH] = length;
          }
        },
        length: { value: 16 },
      });
      const viewMap = new Map(), addressMap = new Map();
      let nextAddress = usize(0x1000);
      const allocator = {
        alloc(len, align) {
          const address = nextAddress;
          nextAddress += usize(0x1000);
          const dv = new DataView(new ArrayBuffer(len));
          dv[ZIG] = { address, len, allocator: this };
          viewMap.set(address, dv);
          addressMap.set(dv, address);
          return dv;
        },
        free(dv) {
        },
      };
      const dv = new DataView(new ArrayBuffer(16));
      dv.setInt8(9, 123);
      env.assignView(target, dv, structure, false, allocator);
      expect(target[MEMORY]).to.not.equal(dv);
      expect(target[MEMORY].getInt8(9)).to.equal(123);
    })
    if (process.env.TARGET === 'node') {
      it('should call fallback function when one is attached to view support', function() {
        const env = new Env();
        const dv = createView(16);
        let syncTo;
        dv[FALLBACK] = (to) => {
          syncTo = to;
        };
        const target = { [MEMORY]: dv };
        const src = createView(16);
        const structure = { byteSize: 16, type: StructureType.Array };
        env.assignView(target, src, structure);
        expect(syncTo).to.be.true;
      })
    }
  })
  describe('allocateMemory', function() {
    it('should return a data view of a newly created array buffer', function() {
      const env = new Env();
      env.getBufferAddress = () => 0x10000;
      const dv = env.allocateMemory(32, 4);
      expect(dv).to.be.instanceOf(DataView);
      expect(dv.byteLength).to.equal(32);
      expect(dv.byteOffset).to.equal(0);
    })
    it('should allocate memory from given allocator', function() {
      const env = new Env();
      const viewMap = new Map(), addressMap = new Map();
      let nextAddress = usize(0x1000);
      const allocator = {
        alloc(len, align) {
          const address = nextAddress;
          nextAddress += usize(0x1000);
          const dv = new DataView(new ArrayBuffer(len));
          dv[ZIG] = { address, len, allocator: this };
          viewMap.set(address, dv);
          addressMap.set(dv, address);
          return dv;
        },
        free(dv) {
        },
      };
      const dv = env.allocateMemory(32, 4, allocator);
      expect(dv).to.be.instanceOf(DataView);
      expect(dv.byteLength).to.equal(32);
      expect(dv[ZIG]).to.be.an('object');
    })
  })
  describe('allocateJSMemory', function() {
    if (process.env.TARGET === 'wasm') {
      it('should allocate relocable memory', function() {
        const env = new Env();
        const dv = env.allocateJSMemory(64, 32);
        expect(dv.byteLength).to.equal(64);
        expect(dv.buffer.byteLength).to.equal(64);
      })
    } else if (process.env.TARGET === 'node') {
      it('should allocate extra bytes to account for alignment', function() {
        const env = new Env();
        env.getBufferAddress = function(buffer) {
          return 0x1000n;
        };
        const dv = env.allocateJSMemory(64, 32);
        expect(dv.byteLength).to.equal(64);
        expect(dv.buffer.byteLength).to.equal(96);
      })
    }
  })
  if (process.env.TARGET === 'node') {
    describe('usingBufferFallback', function() {
      it('should call requireBufferFallback if it exists', function() {
        const env = new Env();
        let called = false;
        env.requireBufferFallback = function() {
          called = true;
          return false;
        };
        const result = env.usingBufferFallback();
        expect(result).to.be.false;
        expect(called).to.be.true;
      })
    })
  } else if (process.env.TARGET === 'wasm') {
    describe('moveExternBytes', function() {
      it('should immediately return when len is zero', function() {
        const env = new Env();
        let called = false;
        const dv = new DataView(new ArrayBuffer(0));
        env.moveExternBytes(dv, 0xabcd, true);
      })
      it('should accept BigInt address in memory64 mode', function() {
        const env = new Env();
        env.memory64 = true;
        env.memory = new WebAssembly.Memory({ initial: 1n, maximum: 2n, address: 'i64' });
        const src = new DataView(new ArrayBuffer(4));
        src.setUint32(0, 0x12345678, true);
        env.moveExternBytes(src, 0x400n, true);
        const dst = new DataView(new ArrayBuffer(4));
        env.moveExternBytes(dst, 0x400n, false);
        expect(dst.getUint32(0, true)).to.equal(0x12345678);
      })
    })
    describe('restoreView and Resizable ArrayBuffer / Growable SharedArrayBuffer', function() {
      it('should keep existing DataViews valid across memory.grow with zero detachment when usingResizableBuffer is true', function() {
        const hasNativeRAB = typeof WebAssembly.Memory.prototype.toResizableBuffer === 'function';

        // 1. Live WebAssembly.Memory.prototype.toResizableBuffer() when available (e.g. --experimental-wasm-rab-integration)
        if (hasNativeRAB) {
          for (const is64 of [ false, true ]) {
            const env = new Env();
            env.memory64 = is64;
            env.memory = new WebAssembly.Memory(is64
              ? { initial: 1n, maximum: 3n, address: 'i64' }
              : { initial: 1, maximum: 3 });
            env.enableResizableMemory(env.memory);
            expect(env.usingResizableBuffer).to.be.true;
            expect(env.memory.buffer.resizable).to.be.true;

            const addr = is64 ? 0x100n : 0x100;
            const dv = env.obtainZigView(addr, 8);
            dv.setUint32(0, 0xcafebabe, true);
            expect(dv[ZIG].address).to.equal(addr);

            env.memory.grow(is64 ? 1n : 1);
            expect(dv.buffer.detached).to.be.false;
            expect(dv.buffer).to.equal(env.memory.buffer);
            expect(dv.byteLength).to.equal(8);
            expect(dv.getUint32(0, true)).to.equal(0xcafebabe);
            expect(env.restoreView(dv)).to.equal(dv);
            expect(env.obtainZigView(addr, 8)).to.equal(dv);
          }
        }

        // 2. Simulated Resizable ArrayBuffer (always runs even without experimental V8 flag)
        const simEnv = new Env();
        const rab = new ArrayBuffer(65536, { maxByteLength: 3 * 65536 });
        simEnv.memory = {
          buffer: rab,
          toResizableBuffer() { return rab; },
          grow(pages) { rab.resize(rab.byteLength + pages * 65536); },
        };
        simEnv.enableResizableMemory(simEnv.memory);
        expect(simEnv.usingResizableBuffer).to.be.true;
        const simDV = simEnv.obtainZigView(256, 8);
        simDV.setUint32(0, 0xdeadbeef, true);
        simEnv.memory.grow(1);
        expect(simDV.buffer.detached).to.be.false;
        expect(simEnv.restoreView(simDV)).to.equal(simDV);
        expect(simEnv.obtainZigView(256, 8)).to.equal(simDV);
        expect(simDV.getUint32(0, true)).to.equal(0xdeadbeef);
      })
      it('should restore detached DataViews after memory.grow when RAB is unavailable or disabled', function() {
        const env = new Env();
        env.useResizableBuffer = false;
        env.memory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
        env.enableResizableMemory(env.memory);
        expect(env.usingResizableBuffer).to.be.false;

        const dv = env.obtainZigView(128, 8);
        dv[ZIG].align = 8;
        dv.setUint32(0, 0x11223344, true);

        env.memory.grow(1);
        expect(dv.buffer.detached).to.be.true;

        const restored = env.restoreView(dv);
        expect(restored).to.not.equal(dv);
        expect(restored.buffer).to.equal(env.memory.buffer);
        expect(restored[ZIG].align).to.equal(8);
        expect(restored.getUint32(0, true)).to.equal(0x11223344);
      })
      it('should restore SharedArrayBuffer views after memory.grow both with and without GSAB', function() {
        const hasNativeRAB = typeof WebAssembly.Memory.prototype.toResizableBuffer === 'function';

        // WITHOUT GSAB (usingResizableBuffer: false): old SAB is NOT detached, but dv.buffer !== memory.buffer
        const envNonGSAB = new Env();
        envNonGSAB.useResizableBuffer = false;
        envNonGSAB.memory = new WebAssembly.Memory({ initial: 1, maximum: 3, shared: true });
        envNonGSAB.enableResizableMemory(envNonGSAB.memory);
        expect(envNonGSAB.usingResizableBuffer).to.be.false;

        const oldDV = envNonGSAB.obtainZigView(64, 8);
        oldDV[ZIG].align = 4;
        oldDV.setUint32(0, 0x55667788, true);
        const oldSAB = oldDV.buffer;

        envNonGSAB.memory.grow(1);
        expect(oldDV.buffer).to.equal(oldSAB);
        expect(oldDV.buffer).to.not.equal(envNonGSAB.memory.buffer);

        const restoredSABView = envNonGSAB.restoreView(oldDV);
        expect(restoredSABView).to.not.equal(oldDV);
        expect(restoredSABView.buffer).to.equal(envNonGSAB.memory.buffer);
        expect(restoredSABView[ZIG].align).to.equal(4);
        expect(restoredSABView.getUint32(0, true)).to.equal(0x55667788);

        // WITH GSAB (usingResizableBuffer: true)
        if (hasNativeRAB) {
          const envGSAB = new Env();
          envGSAB.memory = new WebAssembly.Memory({ initial: 1, maximum: 3, shared: true });
          envGSAB.enableResizableMemory(envGSAB.memory);
          expect(envGSAB.usingResizableBuffer).to.be.true;
          expect(envGSAB.memory.buffer.growable).to.be.true;

          const gsabDV = envGSAB.obtainZigView(64, 8);
          gsabDV.setUint32(0, 0x99aabbcc, true);
          envGSAB.memory.grow(1);
          expect(gsabDV.buffer).to.equal(envGSAB.memory.buffer);
          expect(envGSAB.restoreView(gsabDV)).to.equal(gsabDV);
          expect(envGSAB.obtainZigView(64, 8)).to.equal(gsabDV);
          expect(gsabDV.getUint32(0, true)).to.equal(0x99aabbcc);
        }
      })
    })
  }
})
