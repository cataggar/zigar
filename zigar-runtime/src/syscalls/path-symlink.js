import { PosixError } from '../constants.js';
import { mixin } from '../environment.js';
import { catchPosixError, expectBoolean } from '../errors.js';
import { decodeText } from '../utils.js';

export default mixin({
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
  ...(process.env.TARGET === 'node' ? {
    exports: {
      pathSymlink: { async: true },
    },
    /* c8 ignore next */
  } : undefined),
});
