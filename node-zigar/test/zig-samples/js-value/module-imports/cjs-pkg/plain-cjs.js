exports.count = 1;
exports.bump = function() {
  exports.count += 1;
  return exports.count;
};
