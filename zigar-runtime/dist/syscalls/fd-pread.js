import { PosixError, PosixDescriptorRight } from '../constants.js';
import { mixin } from '../environment.js';
import { catchPosixError, checkAccessRight, checkStreamMethod } from '../errors.js';
import { createView, safeInt } from '../utils.js';
import './copy-int.js';

var fdPread = mixin({
  fdPread(fd, iovsAddress, iovsCount, offset, readAddress, canWait) {
    const le = this.littleEndian;
    const ptrSize = (this.memory64 || "32" == 64) ? 8 : 4;
    const iovsSize = ptrSize * 2;
    const count = Number(iovsCount);
    const ops = [];
    let total = 0;
    return catchPosixError(canWait, PosixError.EIO, () => {        
      const[ reader, rights ] = this.getStream(fd);
      checkAccessRight(rights, PosixDescriptorRight.fd_read);
      checkStreamMethod(reader, 'pread');
      const iovs = createView(iovsSize * count);
      this.moveExternBytes(iovs, iovsAddress, false);
      for (let i = 0; i < count; i++) {
        const ptr = (ptrSize === 8) ? iovs.getBigUint64(i * iovsSize, le) : iovs.getUint32(i * iovsSize, le);
        const len = (ptrSize === 8) ? Number(iovs.getBigUint64(i * iovsSize + 8, le)) : iovs.getUint32(i * iovsSize + 4, le);
        ops.push({ ptr, len });
        total += len;
      }
      return reader.pread(total, safeInt(offset));
    }, (chunk) => {
      let { byteOffset: pos, byteLength: remaining, buffer } = chunk;
      for (const { ptr, len } of ops) {
        if (remaining > 0) {
          const part = new DataView(buffer, pos, Math.min(remaining, len));
          this.moveExternBytes(part, ptr, true);
          pos += len;
          remaining -= len;
        }
      }
      this.copyUsize(readAddress, chunk.length);
    });
  },
});

export { fdPread as default };
