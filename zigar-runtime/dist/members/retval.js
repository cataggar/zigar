import { mixin } from '../environment.js';
import { MEMORY, ZIG } from '../symbols.js';
import { toBufferOffset, copyView } from '../utils.js';

var retval = mixin({
  ...({
    defineRetvalCopier({ byteSize, bitOffset }) {
      if (byteSize > 0) {
        const thisEnv = this;
        const offset = bitOffset >> 3;
        return {
          value(shadowDV) {
            const dv = this[MEMORY];
            const { address } = shadowDV[ZIG];
            const src = new DataView(thisEnv.memory.buffer, toBufferOffset(address) + offset, Number(byteSize));
            const dest = new DataView(dv.buffer, dv.byteOffset + offset, Number(byteSize));
            copyView(dest, src);
          }
        };
      }
    },
  } ),
});

export { retval as default };
