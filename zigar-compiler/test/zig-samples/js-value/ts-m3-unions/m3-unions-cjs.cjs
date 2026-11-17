'use strict';

class MiniChannel {
  constructor(label) {
    this.label = label;
  }

  ping() {
    return `pong:${this.label}`;
  }
}

module.exports = MiniChannel;
