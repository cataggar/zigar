const fn = function(x) {
  return x + fn.extra;
};
fn.extra = 1;
module.exports = fn;
