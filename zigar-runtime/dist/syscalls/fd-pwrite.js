import { PosixError, PosixDescriptorRight } from '../constants.js';
import { mixin } from '../environment.js';
import { catchPosixError, checkAccessRight, checkStreamMethod } from '../errors.js';
import { createView, safeInt } from '../utils.js';
import './copy-int.js';

var fdPwrite = mixin({
  fdPwrite(fd, iovsAddress, iovsCount, offset, writtenAddress, canWait) {
    const le = this.littleEndian;
    const ptrSize = (this.memory64 || "32" == 64) ? 8 : 4;
    const iovsSize = ptrSize * 2;
    const count = Number(iovsCount);
    let total = 0;
    return catchPosixError(canWait, PosixError.EIO, () => {
      const[ writer, rights ] = this.getStream(fd);
      checkAccessRight(rights, PosixDescriptorRight.fd_write);
      checkStreamMethod(writer, 'pwrite');
      const iovs = createView(iovsSize * count);
      this.moveExternBytes(iovs, iovsAddress, false);
      const ops = [];
      for (let i = 0; i < count; i++) {
        const ptr = (ptrSize === 8) ? iovs.getBigUint64(i * iovsSize, le) : iovs.getUint32(i * iovsSize, le);
        const len = (ptrSize === 8) ? Number(iovs.getBigUint64(i * iovsSize + 8, le)) : iovs.getUint32(i * iovsSize + 4, le);
        ops.push({ ptr, len });
        total += len;
      }
      const buffer = new ArrayBuffer(total);
      let pos = 0;
      for (const { ptr, len } of ops) {
        const part = new DataView(buffer, pos, len);
        this.moveExternBytes(part, ptr, false);
        pos += len;
      }
      const chunk = new Uint8Array(buffer);
      return writer.pwrite(chunk, safeInt(offset));
    }, () => this.copyUsize(writtenAddress, total));
  },
});

export { fdPwrite as default };
