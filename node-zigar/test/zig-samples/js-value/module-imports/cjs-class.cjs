class ExportEqualsAccumulator {
  constructor(seed) {
    this.total = seed;
  }

  add(delta) {
    if (!(this instanceof ExportEqualsAccumulator)) {
      throw new TypeError('CJS class method lost instance `this`');
    }
    this.total += delta;
    return this.total;
  }
}

ExportEqualsAccumulator.tag = 'cjs-ctor-tag';

module.exports = ExportEqualsAccumulator;
