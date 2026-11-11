import { mixin } from '../environment.js';
import { createView } from '../utils.js';

var copyInt = mixin({
  copyUint64(bufAddress, value) {
    const buf = createView(8);
    buf.setBigUint64(0, BigInt(value), this.littleEndian);
    this.moveExternBytes(buf, bufAddress, true);
  },
  copyUint32(bufAddress, value) {
    const buf = createView(4);    
    buf.setUint32(0, Number(value), this.littleEndian);
    this.moveExternBytes(buf, bufAddress, true);
  },
  copyUsize(bufAddress, value) {
    if (this.memory64) {
      this.copyUint64(bufAddress, BigInt(value));
    } else {
      this.copyUint32(bufAddress, Number(value));
    }
  },
});

export { copyInt as default };
