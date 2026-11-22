import { expect } from 'chai';
import { capture } from '../test-utils.js';

export function addTests(importModule, options) {
  const importTest = async (name) => {
      const url = new URL(`./${name}.zig`, import.meta.url).href;
      return importModule(url);
  };
  describe('Memory allocation', function() {
    this.timeout(0);
    it('should provide allocator to function returning string', async function() {
      const { getMessage } = await importTest('allocate-memory-for-string');;
      const { string } = getMessage(123, 456n, 3.14);
      expect(string).to.equal('Numbers: 123, 456, 3.14');
    })
    it('should return memory from internal allocator', async function() {
      const { createSlice, printSlice, freeSlice } = await importTest('create-internal-slice');
      for (let i = 0; i < 10; i++) {
        const slice = createSlice(16);
        for (let i = 0, { length, set } = slice; i < length; i++) {
          set(i, (i + 1) * 10);
        }
        const lines = await capture(() => {
          printSlice(slice);
        });
        expect(lines).to.eql([
          '10', '20', '30', '40',
          '50', '60', '70', '80',
          '90', '100', '110', '120',
          '130', '140', '150', '160',
        ]);
        expect(() => freeSlice(slice)).to.not.throw();
      }
    })
    it('should keep a usable copy of allocator', async function() {
      const { create } = await importTest('retain-allocator');
      const copier = create();
      const copy1 = copier.dupe('Hello world');
      expect(copy1.string).to.equal('Hello world');
      const copy2 = copier.dupe('This is a test');
      expect(copy2.string).to.equal('This is a test');
    })
    it('should return a Zig allocator', async function() {
      const {
        Struct,
        getAllocator,
        print,
        default: module } = await importTest('return-allocator');
      const allocator = getAllocator();
      const struct = new Struct({ number1: 123, number2: 456 }, { allocator });
      expect(struct.valueOf()).to.eql({ number1: 123, number2: 456 });
      module.ptr_maybe = struct;
      const [ after ] = await capture(() => print());
      expect(after).to.equal('.{ .number1 = 123, .number2 = 456 }');
      module.ptr_maybe = null;
      allocator.free(struct);
      const msg = 'Hello world';
      const dv1 = allocator.dupe(msg);
      expect(dv1.byteLength).to.equal(msg.length);
      for (let i = 0; i < msg.length; i++) {
        expect(dv1.getUint8(i)).to.equal(msg.charCodeAt(i));
      }
      const array = new Float64Array([ 1.1, 2.2, 3.3, 4.4, 5.5 ]);
      const dv2 = allocator.dupe(array);
      expect(dv2.byteLength).to.equal(array.length * 8);
      for (let i = 0; i < array.length; i++) {
        expect(dv2.getFloat64(i * 8, true)).to.equal(array[i]);
      }
      allocator.free(dv2);
    })
    it('should use returned allocator in call', async function() {
      const {
        Struct,
        default_allocator,
        alloc,
      } = await importTest('allocate-from-zig-allocator');
      const struct = new Struct({ number1: 123, number2: 456 }, { allocator: default_allocator });
      expect(struct.valueOf()).to.eql({ number1: 123, number2: 456 });
      default_allocator.free(struct);
      const ptr = alloc({ allocator: default_allocator });
      expect(ptr.valueOf()).to.eql({ number1: 123, number2: 456 });
      default_allocator.free(ptr);
    })
    it('should track both Zig-internal and cross-boundary allocations via zigar.mem.TrackingAllocator', async function() {
      const {
        tracked_allocator,
        activeCount,
        activeBytes,
        formatGreeting,
        exerciseInternalRealloc,
      } = await importTest('tracking-allocator');
      expect(Number(activeCount())).to.equal(0);
      expect(Number(activeBytes())).to.equal(0);

      const dv = tracked_allocator.dupe('Hello Zigar!');
      expect(Number(activeCount())).to.equal(1);
      expect(Number(activeBytes())).to.equal(12);
      tracked_allocator.free(dv);
      expect(Number(activeCount())).to.equal(0);
      expect(Number(activeBytes())).to.equal(0);

      const greeting = formatGreeting('TrackingAllocator', { allocator: tracked_allocator });
      expect(greeting.string).to.equal('Hello, TrackingAllocator!');
      expect(Number(activeCount())).to.equal(1);
      expect(Number(activeBytes())).to.equal(greeting.length);
      tracked_allocator.free(greeting);
      expect(Number(activeCount())).to.equal(0);
      expect(Number(activeBytes())).to.equal(0);

      const peak = exerciseInternalRealloc();
      expect(Number(peak)).to.equal(256);
      expect(Number(activeCount())).to.equal(0);
      expect(Number(activeBytes())).to.equal(0);
    })
  })
}