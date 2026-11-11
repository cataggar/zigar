import { mixin } from '../environment.js';
import { MEMORY, RESET } from '../symbols.js';
import '../utils.js';

var allocator = mixin({
  init() {
    this.defaultAllocator = null;
    this.allocatorContextMap = new Map();
    this.nextAllocatorContextId = 0x1000;
  },
  createDefaultAllocator(args, structure) {
    return this.defaultAllocator ??= this.createJsAllocator(args, structure, false);
  },
  createJsAllocator(args, structure, resettable) {
    const { constructor: Allocator } = structure;
    const { noResize, noRemap } = Allocator;
    const vtable = {
      alloc: this.allocateHostMemory.bind(this),
      free: this.freeHostMemory.bind(this),
      resize: noResize,
    };
    if (noRemap) {
      vtable.remap = noRemap;
    }
    this.destructors.push(() => this.freeFunction(vtable.alloc));
    this.destructors.push(() => this.freeFunction(vtable.free));
    const is64 = Boolean(this.memory64 || "32" == 64);
    const maxAddr = is64 ? 0xFFFF_FFFF_FFFF_FFFFn : 0xFFFF_FFFF;
    let contextId = maxAddr;
    if (resettable) {
      // create list used to clean memory allocated for generator
      const list = [];
      const id = this.nextAllocatorContextId++;
      contextId = is64 ? BigInt(id) : id;
      this.allocatorContextMap.set(contextId, list);
      args[RESET] = (done) => {
        for (const { address, len } of list) {
          const entry = this.unregisterMemory(address, len);
          {
            if (entry) {
              this.freeShadowMemory(entry.shadowDV);
            }
          }
          if (done) {
            this.allocatorContextMap.delete(contextId);
          }
        }
        list.splice(0);
      };
    }
    const ptr = this.obtainZigView(contextId, 0);
    return new Allocator({ ptr, vtable });
  },
  allocateHostMemory(ptr, len, ptrAlign) {
    len = Number(len);
    const is64 = Boolean(this.memory64 || "32" == 64);
    const maxAddr = is64 ? 0xFFFF_FFFF_FFFF_FFFFn : 0xFFFF_FFFF;
    // see if we're dealing with a resettable allocator
    const contextId = this.getViewAddress(ptr['*'][MEMORY]);
    const list = (contextId !== maxAddr) ? this.allocatorContextMap.get(contextId) : null;
    const align = 1 << ptrAlign;
    const targetDV = this.allocateJSMemory(len, align);
    {
      try {
        const shadowDV = this.allocateShadowMemory(len, align);
        const address = this.getViewAddress(shadowDV);
        this.registerMemory(address, len, align, true, targetDV, shadowDV);
        // save address and len if resettable
        list?.push({ address, len });
        return shadowDV;
      } catch (err) {
        return null;
      }
    }
  },
  freeHostMemory(ptr, buf, ptrAlign) {
    const dv = buf['*'][MEMORY];
    const address = this.getViewAddress(dv);
    const len = dv.byteLength;
    const entry = this.unregisterMemory(address, len);
    {
      if (entry) {
        this.freeShadowMemory(entry.shadowDV);
      }
    }
  },
});

export { allocator as default };
