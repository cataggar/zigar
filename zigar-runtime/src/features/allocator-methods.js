import { StructureType } from '../constants.js';
import { mixin } from '../environment.js';
import { PreviouslyFreed, TypeMismatch } from '../errors.js';
import { ALIGN, MEMORY, TYPE, ZIG } from '../symbols.js';
import { copyView, defineProperty, encodeText, isInvalidUsize } from '../utils.js';

export default mixin({
  defineAlloc() {
    const thisEnv = this;
    return {
      value(len, align = 1) {
        const lz = Math.clz32(align);        
        if (align !== 1 << (31 - lz)) {
          throw new Error(`Invalid alignment: ${align}`);
        }
        const byteLen = Number(len);
        if (byteLen === 0) {
          // Zig 0.17 Allocator.VTable.alloc asserts n > 0; zero-length slices carry a
          // non-null aligned dangling pointer and skip vtable.alloc / vtable.free.
          const is64 = Boolean(thisEnv.memory64 || process.env.BITS == 64);
          const address = is64 ? BigInt(align) : align;
          const dv = new DataView(new ArrayBuffer(0));
          defineProperty(dv, ZIG, { value: { address, len: 0, align }, writable: true, configurable: true, enumerable: false });
          return dv;
        }
        const ptrAlign = 31 - lz;
        const { vtable: { alloc }, ptr } = this;
        const slicePtr = alloc(ptr, len, ptrAlign, 0);
        if (!slicePtr) {
          throw new Error('Out of memory');
        }
        let dv;
        if (slicePtr instanceof DataView) {
          dv = slicePtr;
        } else {
          // alloc returns a [*]u8, which has a initial length of 1
          slicePtr.length = len;
          dv = slicePtr['*'][MEMORY];
        }
        if (!dv[ZIG]) {
          // Re-attach the one-shot JS-backed Zig tag consumed by vtable.alloc's return pointer
          const address = thisEnv.getViewAddress(dv);
          defineProperty(dv, ZIG, { value: { address, len, align, js: true }, writable: true, configurable: true, enumerable: false });
        } else {
          // attach alignment so we can find it again
          dv[ZIG].align = align;
        }
        return dv;
      }
    };
  },
  defineFree() {
    const thisEnv = this;
    return {
      value(arg) {
        const { dv, align } = getMemory(arg)
        const zig = dv?.[ZIG];
        if (!zig) {
          throw new TypeMismatch('object containing allocated Zig memory', arg);
        }
        const { address } = zig;
        if (isInvalidUsize(address)) {
          throw new PreviouslyFreed(arg);
        }
        if (dv.byteLength > 0) {
          const { vtable: { free }, ptr } = this;
          const ptrAlign = 31 - Math.clz32(align);        
          free(ptr, dv, ptrAlign, 0);
        }
        thisEnv.releaseZigView(dv);
      }
    };
  },
  defineDupe() {
    return {
      value(arg) {
        const { dv: src, align, constructor } = getMemory(arg);
        if (!src) {
          throw new TypeMismatch('string, DataView, typed array, or Zig object', arg);
        }
        const dest = this.alloc(src.byteLength, align);
        copyView(dest, src);
        return (constructor) ? constructor(dest) : dest;
      }
    };
  }
});

function getMemory(arg) {
  let dv, align = 1, constructor = null;
  if (arg instanceof DataView) {
    dv = arg;
    const zigMemoryAlign = dv?.[ZIG]?.align;
    if (zigMemoryAlign) {
      align = zigMemoryAlign;
    }
  } else if (arg instanceof ArrayBuffer) {
    dv = new DataView(arg);
  } else if (arg) {
    if (arg[MEMORY]) {
      if (arg.constructor[TYPE] === StructureType.Pointer) {
        arg = arg['*'];
      }
      dv = arg[MEMORY];
      constructor = arg.constructor;
      align = constructor[ALIGN];
    } else {
      if (typeof(arg) === 'string') {
        arg = encodeText(arg);
      }
      const { buffer, byteOffset, byteLength, BYTES_PER_ELEMENT } = arg;
      if (buffer && byteOffset !== undefined && byteLength !== undefined) {
        dv = new DataView(buffer, byteOffset, byteLength);
        align = BYTES_PER_ELEMENT;
      }
    }
  }
  return { dv, align, constructor };
}