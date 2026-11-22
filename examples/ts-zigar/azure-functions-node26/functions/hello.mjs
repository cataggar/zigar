import {
  registerHttpTriggers,
  invokeHttp,
  activeAllocCount,
  activeJsHandleCount,
  activeJsCallbackCount,
} from '../dist/azure-func.mjs';

export async function helloHandler(request, context) {
  const res = await invokeHttp(request, context);
  return res?.$ ?? res;
}

export function register() {
  registerHttpTriggers(helloHandler);
}

register();

export { activeAllocCount, activeJsHandleCount, activeJsCallbackCount };
