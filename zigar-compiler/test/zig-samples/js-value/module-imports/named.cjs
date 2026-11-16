exports.counter = 1;
exports.bump = function() {
  exports.counter += 1;
  return exports.counter;
};
