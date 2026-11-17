'use strict';

function callableToolkit(a, b) {
  if (typeof a === 'string') {
    return `TK:${a}`;
  }
  return Number(a) + Number(b);
}

callableToolkit.joinParts = function joinParts(sep, ...parts) {
  return parts.join(sep);
};

module.exports = callableToolkit;
