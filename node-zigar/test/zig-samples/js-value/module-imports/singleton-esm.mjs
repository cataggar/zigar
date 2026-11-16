export let live = 1;
export let visits = 0;

export function recordVisit(delta) {
  visits += delta;
  return visits;
}

const defaultExport = {
  live: 100,
  onlyOnDefault: 42,
};

export default defaultExport;
