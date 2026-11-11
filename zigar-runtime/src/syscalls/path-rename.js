import { PosixError } from '../constants.js';
import { mixin } from '../environment.js';
import { catchPosixError, expectBoolean } from '../errors.js';

export default mixin({
  pathRenameEvent: 'rename',
  pathRename(dirFd, pathAddress, pathLen, newDirFd, newPathAddress, newPathLen, canWait) {
    return catchPosixError(canWait, PosixError.ENOENT, () => {
      const loc = this.obtainStreamLocation(dirFd, pathAddress, Number(pathLen));
      const { 
        path: newPath, 
        parent: newParent,
      } = this.obtainStreamLocation(newDirFd, newPathAddress, Number(newPathLen));
      return this.triggerEvent('rename', { ...loc, newParent, newPath }, PosixError.ENOENT);
    }, (result) => (result === undefined) ? PosixError.ENOTSUP : expectBoolean(result, PosixError.ENOENT));
  },
  ...(process.env.TARGET === 'node' ? {
    exports: {
      pathRename: { async: true },
    },
    /* c8 ignore next */
  } : undefined),
});
