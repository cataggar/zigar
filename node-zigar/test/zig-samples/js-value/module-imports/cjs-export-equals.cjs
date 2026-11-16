function computeExportEquals(a, b) {
  return a * 100 + b;
}

computeExportEquals.extra = 'cjs-static-extra';
computeExportEquals.describe = function describe(label) {
  if (this !== computeExportEquals) {
    throw new TypeError('CJS static method lost `this` binding');
  }
  return `${this.extra}:${label}`;
};

module.exports = computeExportEquals;
