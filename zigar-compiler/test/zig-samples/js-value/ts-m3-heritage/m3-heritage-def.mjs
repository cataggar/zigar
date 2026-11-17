let callCounter = 0;

function defaultCreate(label, count) {
  callCounter += 1;
  if (arguments.length >= 2) {
    return `def[${defaultCreate.version}]:${label}x${count}#${callCounter}`;
  }
  return `def[${defaultCreate.version}]:${label}#${callCounter}`;
}

defaultCreate.version = '1.0';
defaultCreate.reset = function reset() {
  const prev = callCounter;
  callCounter = 0;
  return prev;
};

export default defaultCreate;
