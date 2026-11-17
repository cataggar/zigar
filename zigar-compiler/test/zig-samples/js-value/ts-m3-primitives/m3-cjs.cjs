'use strict';

function cjsTransform(prefix, code = 7) {
  cjsTransform.invocations += 1;
  return [ `${prefix}:${arguments.length}`, code * 10 + cjsTransform.invocations ];
}

cjsTransform.invocations = 0;
cjsTransform.gUndef = 'cjs-initial-undef';
cjsTransform.gNull = 'cjs-initial-null';
cjsTransform.describe = function describe(tag) {
  return tag === null ? 'cjs:null' : `cjs:${tag}`;
};
cjsTransform.verifyCjsNullishGlobals = function verifyCjsNullishGlobals() {
  const u = cjsTransform.gUndef === undefined
    ? 'undefined'
    : cjsTransform.gUndef === null ? 'null' : `str:${cjsTransform.gUndef}`;
  const n = cjsTransform.gNull === null
    ? 'null'
    : cjsTransform.gNull === undefined ? 'undefined' : `str:${cjsTransform.gNull}`;
  return `cjs:${u}|${n}`;
};

module.exports = cjsTransform;
