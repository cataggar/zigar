export const version = 17;

export function formatPair(left, right) {
  return `${left}<->${right}`;
}

export function unusedDeadCodeMarker() {
  return 'UNUSED_DEAD_CODE_MARKER_DO_NOT_CALL';
}

export default function greetDefault(who) {
  return `esm-default:${who}`;
}
