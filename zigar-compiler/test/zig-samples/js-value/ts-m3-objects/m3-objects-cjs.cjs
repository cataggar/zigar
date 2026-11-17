'use strict';

class CjsSocket {
  constructor(port) {
    this.port = Number(port);
    this._refed = true;
  }

  ref() {
    this._refed = true;
    return this;
  }

  unref() {
    this._refed = false;
    return this;
  }

  isRefed() {
    return this._refed;
  }
}

module.exports = CjsSocket;
