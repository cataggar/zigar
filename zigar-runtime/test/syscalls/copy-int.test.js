import { expect } from 'chai';
import { defineEnvironment } from '../../src/environment.js';
import '../../src/mixins.js';
import { copyView, usize } from '../../src/utils.js';

const Env = defineEnvironment();

describe('Syscall helper', function() {
  describe('copyUint32', function() {
    it('should write u32 to given address', function() {
      const env = new Env();
      if (process.env.TARGET === 'wasm') {
        env.memory = new WebAssembly.Memory({ initial: 1 });
      } else {
        const map = new Map();
        env.obtainExternBuffer = function(address, len) {
          let buffer = map.get(address);
          if (!buffer) {
            buffer = new ArrayBuffer(len);
            map.set(address, buffer);
          }
          return buffer;
        };
        env.moveExternBytes = function(jsDV, address, to) {
          const len = jsDV.byteLength;
          const zigDV = this.obtainZigView(address, len);
          if (!(jsDV instanceof DataView)) {
            jsDV = new DataView(jsDV.buffer, jsDV.byteOffset, jsDV.byteLength);
          }
          copyView(to ? zigDV : jsDV, to ? jsDV : zigDV);
        };
      }   
      const address = usize(0x3000);
      const number = 1234;
      env.copyUint32(address, number);
      const dv = env.obtainZigView(address, 4);
      const result = dv.getUint32(0, env.littleEndian);
      expect(result).to.equal(number);
    })
  })
  describe('copyUint64', function() {
    it('should write u64 to given address', function() {
      const env = new Env();
      if (process.env.TARGET === 'wasm') {
        env.memory = new WebAssembly.Memory({ initial: 1 });
      } else {
        const map = new Map();
        env.obtainExternBuffer = function(address, len) {
          let buffer = map.get(address);
          if (!buffer) {
            buffer = new ArrayBuffer(len);
            map.set(address, buffer);
          }
          return buffer;
        };
        env.moveExternBytes = function(jsDV, address, to) {
          const len = jsDV.byteLength;
          const zigDV = this.obtainZigView(address, len);
          if (!(jsDV instanceof DataView)) {
            jsDV = new DataView(jsDV.buffer, jsDV.byteOffset, jsDV.byteLength);
          }
          copyView(to ? zigDV : jsDV, to ? jsDV : zigDV);
        };
      }   
      const address = usize(0x3000);
      const number = 1234;
      env.copyUint64(address, number);
      const dv = env.obtainZigView(address, 8);
      const result = dv.getBigUint64(0, env.littleEndian);
      expect(result).to.equal(BigInt(number));
    })
  })
  describe('copyUsize', function() {
    it('should write u32 without clobbering adjacent 4 bytes when memory64 is not enabled', function() {
      const env = new Env();
      let backingBuffer;
      if (process.env.TARGET === 'wasm') {
        env.memory = new WebAssembly.Memory({ initial: 1 });
        backingBuffer = env.memory.buffer;
        new DataView(backingBuffer, 0x3000, 8).setUint32(4, 0xdead_beef, env.littleEndian);
      } else {
        backingBuffer = new ArrayBuffer(8);
        new DataView(backingBuffer).setUint32(4, 0xdead_beef, env.littleEndian);
        env.obtainExternBuffer = function() {
          return backingBuffer;
        };
        env.moveExternBytes = function(jsDV, address, to) {
          const len = jsDV.byteLength;
          const zigDV = new DataView(backingBuffer, 0, len);
          if (!(jsDV instanceof DataView)) {
            jsDV = new DataView(jsDV.buffer, jsDV.byteOffset, jsDV.byteLength);
          }
          copyView(to ? zigDV : jsDV, to ? jsDV : zigDV);
        };
      }
      const address = usize(0x3000);
      env.copyUsize(address, 1234);
      const checkDV = (process.env.TARGET === 'wasm')
        ? new DataView(backingBuffer, 0x3000, 8)
        : new DataView(backingBuffer, 0, 8);
      expect(checkDV.getUint32(0, env.littleEndian)).to.equal(1234);
      expect(checkDV.getUint32(4, env.littleEndian)).to.equal(0xdead_beef);
    })
    if (process.env.TARGET === 'wasm') {
      it('should write u64 when memory64 is enabled', function() {
        const env = new Env();
        env.memory = new WebAssembly.Memory({ initial: 1n, address: 'i64' });
        env.memory64 = true;
        const raw = new DataView(env.memory.buffer, 0x3000, 8);
        raw.setUint32(4, 0xaaaa_aaaa, env.littleEndian);
        env.copyUsize(0x3000n, 1234);
        expect(raw.getBigUint64(0, env.littleEndian)).to.equal(1234n);
      })
    }
  })
})
