import { expect } from 'chai';
import { PosixDescriptor, PosixError } from '../../src/constants.js';
import { defineEnvironment } from '../../src/environment.js';
import '../../src/mixins.js';
import { copyView, usize } from '../../src/utils.js';
import { captureError } from '../test-utils.js';

const Env = defineEnvironment();

describe('Syscall: path-symlink', function() {
  it('should call listener', async function() {
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
      env.setRedirectionMask = () => {};
    }
    let event;
    env.addListener('symlink', (evt) => {
      if (event) return false;
      event = evt;
      return true;
    });
    const path = new TextEncoder().encode('/hello.txt');
    const pathAddress = usize(0x1000);
    const pathLen = path.length;
    const newPath = new TextEncoder().encode('/world.txt');
    const newPathAddress = usize(0x2000);
    const newPathLen = path.length;
    env.moveExternBytes(path, pathAddress, true);
    env.moveExternBytes(newPath, newPathAddress, true);
    const result1 = env.pathSymlink(pathAddress, pathLen, PosixDescriptor.root, newPathAddress, newPathLen);
    expect(result1).to.equal(0);
    expect(event).to.eql({ 
      parent: null,
      path: 'world.txt',
      target: '/hello.txt',
    });
    const result2 = env.pathSymlink(pathAddress, pathLen, PosixDescriptor.root, newPathAddress, newPathLen);
    expect(result2).to.equal(PosixError.ENOENT);
  })
  it('should display error when listener does not return a boolean', async function() {
    const env = new Env();
    env.memory = new WebAssembly.Memory({ initial: 1 });
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
      env.setRedirectionMask = () => {};
    }
    env.addListener('symlink', () => 'hello');
    const path = new TextEncoder().encode('/hello.txt');
    const pathAddress = usize(0x1000);
    const pathLen = path.length;
    const newPath = new TextEncoder().encode('/world.txt');
    const newPathAddress = usize(0x2000);
    const newPathLen = path.length;
    env.moveExternBytes(path, pathAddress, true);
    env.moveExternBytes(newPath, newPathAddress, true);
    let result 
    const [ error ] = await captureError(() => {
      result = env.pathSymlink(pathAddress, pathLen, PosixDescriptor.root, newPathAddress, newPathLen);
    });
    expect(result).to.equal(PosixError.ENOENT);
    expect(error).to.contain('boolean');
  })
  it('should return return ENOTSUP when listener returns undefined', async function() {
    const env = new Env();
    env.memory = new WebAssembly.Memory({ initial: 1 });
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
      env.setRedirectionMask = () => {};
    }
    env.addListener('unlink', () => undefined);
    const path = new TextEncoder().encode('/hello.txt');
    const pathAddress = usize(0x1000);
    const pathLen = path.length;
    const newPath = new TextEncoder().encode('/world.txt');
    const newPathAddress = usize(0x2000);
    const newPathLen = path.length;
    env.moveExternBytes(path, pathAddress, true);
    env.moveExternBytes(newPath, newPathAddress, true);
    const result = env.pathSymlink(pathAddress, pathLen, PosixDescriptor.root, newPathAddress, newPathLen);
    expect(result).to.equal(PosixError.ENOTSUP);
  })
  if (process.env.TARGET === 'wasm') {
    it('should be callable through WASI', async function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1 });
      let event;
      env.addListener('symlink', (evt) => {
        if (event) return false;
        event = evt;
        return true;
      });
      const path = new TextEncoder().encode('/hello.txt');
      const pathAddress = usize(0x1000);
      const pathLen = path.length;
      const newPath = new TextEncoder().encode('/world.txt');
      const newPathAddress = usize(0x2000);
      const newPathLen = path.length;
      env.moveExternBytes(path, pathAddress, true);
      env.moveExternBytes(newPath, newPathAddress, true);
      const f = env.getWASIHandler('path_symlink');
      const result1 = f(pathAddress, pathLen, PosixDescriptor.root, newPathAddress, newPathLen);
      expect(result1).to.equal(0);
      expect(event).to.eql({ 
        parent: null,
        path: 'world.txt',
        target: '/hello.txt',
      });
      const result2 = f(pathAddress, pathLen, PosixDescriptor.root, newPathAddress, newPathLen);
      expect(result2).to.equal(PosixError.ENOENT);
    })
    it('should accept BigInt target/path pointers and lengths when memory64 is enabled', async function() {
      const env = new Env();
      env.memory = new WebAssembly.Memory({ initial: 1n, address: 'i64' });
      env.memory64 = true;
      let event;
      env.addListener('symlink', (evt) => {
        event = evt;
        return true;
      });
      const target = new TextEncoder().encode('/hello.txt');
      const linkPath = new TextEncoder().encode('/world.txt');
      new Uint8Array(env.memory.buffer, 0x1000, target.length).set(target);
      new Uint8Array(env.memory.buffer, 0x2000, linkPath.length).set(linkPath);
      const result = env.pathSymlink(0x1000n, BigInt(target.length), PosixDescriptor.root, 0x2000n, BigInt(linkPath.length));
      expect(result).to.equal(0);
      expect(event).to.eql({
        parent: null,
        path: 'world.txt',
        target: '/hello.txt',
      });
    })
  }
})
