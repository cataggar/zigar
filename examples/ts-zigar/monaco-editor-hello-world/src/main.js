// Register standalone Monaco browser editor widget + TypeScript support (tree-shaken: no unused language grammars).
import 'monaco-editor/internal/common/workers.js';
import 'monaco-editor/languages/definitions/typescript/register.js';
import 'monaco-editor/languages/features/typescript/register.js';

import * as zigApp from './app.zig';

zigApp.mount('container');

// Expose app controller for interactive inspection, HMR disposal, and automated smoke tests.
globalThis.__zigarMonacoApp = zigApp;

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    try {
      zigApp.unmount();
    } catch {}
  });
}

window.addEventListener('pagehide', (event) => {
  if (!event.persisted) {
    try {
      zigApp.unmount();
    } catch {}
  }
});
