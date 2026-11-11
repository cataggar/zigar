import { PosixError } from '../constants.js';
import { mixin } from '../environment.js';
import { catchPosixError, expectBoolean } from '../errors.js';
import { decodeText } from '../utils.js';

var pathSymlink = mixin({
  pathSymlinkEvent: 'symlink',
  pathSymlink(targetAddress, targetLen, dirFd, pathAddress, pathLen, canWait) {
    return catchPosixError(canWait, PosixError.ENOENT, () => {
      const targetDV = this.obtainZigView(targetAddress, Number(targetLen), false);
      const targetArray = new Uint8Array(targetDV.buffer, targetDV.byteOffset, targetDV.byteLength);
      const target = decodeText(targetArray).trim();
      const loc = this.obtainStreamLocation(dirFd, pathAddress, Number(pathLen));
      return this.triggerEvent('symlink', { ...loc, target }, PosixError.ENOENT);
    }, (result) => (result === undefined) ? PosixError.ENOTSUP : expectBoolean(result, PosixError.ENOENT));
  },
});

export { pathSymlink as default };
