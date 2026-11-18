'use strict';

const cjsGenerics = {
  makeBox(value, revision) {
    return {
      value,
      revision: revision !== undefined && revision !== null ? Number(revision) : 1,
    };
  },
  pluckKey(target, key) {
    return target[key];
  },
};

module.exports = cjsGenerics;
