'use strict';

function cjsTransform(prefix, code = 7) {
  cjsTransform.invocations += 1;
  return [ `${prefix}:${arguments.length}`, code * 10 + cjsTransform.invocations ];
}

cjsTransform.invocations = 0;
cjsTransform.describe = function describe(tag) {
  return tag === null ? 'cjs:null' : `cjs:${tag}`;
};

module.exports = cjsTransform;
