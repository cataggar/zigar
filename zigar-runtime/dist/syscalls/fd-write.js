import { PosixError, PosixDescriptorRight, PosixDescriptorFlag } from '../constants.js';
import { mixin } from '../environment.js';
import { catchPosixError, checkAccessRight } from '../errors.js';
import { createView } from '../utils.js';
import './copy-int.js';

var fdWrite = mixin({
  fdWrite(fd, iovsAddress, iovsCount, writtenAddress, canWait) {
    const le = this.littleEndian;
    const ptrSize = (this.memory64 || "32" == 64) ? 8 : 4;
    const iovsSize = ptrSize * 2;
    const count = Number(iovsCount);
    let total = 0;
    return catchPosixError(canWait, PosixError.EBADF, () => {
      const[ writer, rights, flags ] = this.getStream(fd);
      checkAccessRight(rights, PosixDescriptorRight.fd_write);
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
      const method = (flags & PosixDescriptorFlag.nonblock) ? writer.writenb : writer.write;
      return method.call(writer, chunk);
    }, () => { 
      if (writtenAddress) {
        this.copyUsize(writtenAddress, total);
      }
    });
  },
  fdWriteStderr(chunk, canWait) {
    catchPosixError(canWait, PosixError.EBADF, () => {
      const[ writer, rights, flags ] = this.getStream(2);
      checkAccessRight(rights, PosixDescriptorRight.fd_write);
      return writer.write(chunk);
    });
    return 0;
  },
});

export { fdWrite as default };
