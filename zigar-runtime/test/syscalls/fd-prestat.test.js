import { expect } from 'chai';
import { PosixError } from '../../src/constants.js';
import { defineEnvironment } from '../../src/environment.js';
import '../../src/mixins.js';

const Env = defineEnvironment();

describe('Syscall: fd-prestat-get', function() {
  if (process.env.TARGET === 'wasm') {
    it('should return no error when descriptor 3 is given', function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1 });
      const fd = 3;
      const bufAddress = 0x2000;
      const result = env.fdPrestatGet(fd, bufAddress);
      expect(result).to.equal(PosixError.NONE);
      const dv = new DataView(env.memory.buffer);
      const count = dv.getUint8(bufAddress);
      expect(count).to.equal(0);
      const len1 = dv.getUint32(bufAddress + 4, true);
      expect(len1).to.equal(0);
    })
    it('should write 16-byte prestat_t when memory64 is enabled', function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1n, address: 'i64' });
      env.memory64 = true;
      const bufAddress = 0x2000;
      new Uint8Array(env.memory.buffer, bufAddress, 16).fill(0xff);
      const result = env.fdPrestatGet(3, BigInt(bufAddress));
      expect(result).to.equal(PosixError.NONE);
      const dv = new DataView(env.memory.buffer);
      expect(dv.getUint8(bufAddress)).to.equal(0);
      expect(dv.getBigUint64(bufAddress + 8, true)).to.equal(0n);
    })
    it('should return EBADF when descriptor is not 3', function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1 });
      const fd = 1;
      const bufAddress = 0x2000;
      const result = env.fdPrestatGet(fd, bufAddress);
      expect(result).to.equal(PosixError.EBADF);
    })
    it('should return ENOTSUP when there is a custom handle', function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1 });
      env.customWASI = {
        wasiImport: {
          fd_prestat_get() {
            return PosixError.NONE;
          }
        }
      };
      const fd = 1;
      const bufAddress = 0x2000;
      const result = env.fdPrestatGet(fd, bufAddress);
      expect(result).to.equal(PosixError.ENOTSUP);
    })
    it('should be callable throuh WASI', function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1 });
      env.customWASI = {
        wasiImport: {
          fd_prestat_get() {
            return PosixError.NONE;
          }
        }
      };
      const fd = 1;
      const bufAddress = 0x2000;
      const f = env.getWASIHandler('fd_prestat_get');
      const result = f(fd, bufAddress);
      expect(result).to.equal(PosixError.NONE);
    })
  }
})
