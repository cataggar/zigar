import { mixin } from '../environment.js';
import { createView } from '../utils.js';

var environGet = mixin({
  environGet(environAddress, environBufAddress) {
    const arrays = this.envVarArrays;
    let size = 0, count = 0;
    for (const array of arrays) {
      size += array.length;
      count++;
    }
    const is64 = Boolean(this.memory64 || "32" == 64);
    const ptrSize = is64 ? 8 : 4;
    const ptrDV = createView(ptrSize * count);
    const bytes = new Uint8Array(size);
    let p = 0, b = 0, le = this.littleEndian;
    for (const array of arrays) {
      if (is64) {
        ptrDV.setBigUint64(p, BigInt(environBufAddress) + BigInt(b), le);
        p += 8;
      } else {
        ptrDV.setUint32(p, Number(environBufAddress) + b, le);
        p += 4;
      }
      bytes.set(array, b);
      b += array.length;
    }
    this.moveExternBytes(ptrDV, environAddress, true);
    this.moveExternBytes(bytes, environBufAddress, true);
    return 0;
  },
});

export { environGet as default };
