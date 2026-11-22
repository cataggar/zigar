import {
  invoke,
  activeAllocCount,
  activeJsHandleCount,
  activeJsCallbackCount,
} from './dist/lambda.mjs';

export async function handler(event, context) {
  const res = await invoke(event, context);
  return res?.$ ?? res;
}

export { activeAllocCount, activeJsHandleCount, activeJsCallbackCount };
