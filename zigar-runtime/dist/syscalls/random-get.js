import { mixin } from '../environment.js';
import { createView } from '../utils.js';

var randomGet = mixin({
  randomGet(bufAddress, bufLen) {
    const len = Number(bufLen);
    const dv = createView(len);
    for (let i = 0; i < len; i++) {
      dv.setUint8(i, Math.floor(256 * Math.random()));
    }
    this.moveExternBytes(dv, bufAddress, true);
    return 0;
  }
}) ;

export { randomGet as default };
