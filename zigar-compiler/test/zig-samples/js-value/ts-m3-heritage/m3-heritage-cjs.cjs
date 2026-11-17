'use strict';

class SelectionImpl {
  constructor(selector, root) {
    this.selector = selector;
    this.root = root;
    this.length = root ? 2 : 1;
  }

  text() {
    return this.root ? `${this.root}>>${this.selector}` : this.selector;
  }
}

function $(selector, root) {
  return new SelectionImpl(selector, arguments.length >= 2 ? root : undefined);
}

$.version = '4.9.0';
$.ajax = function ajax(url) {
  return `ajax[${$.version}]:${url}`;
};

module.exports = $;
