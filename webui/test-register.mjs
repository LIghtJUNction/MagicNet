import { registerHooks } from 'node:module';
import { statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Unit fixtures transpile individual helpers into temporary directories. Resolve
// application aliases from the source tree, including the shared locale runtime.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (!specifier.startsWith('@/')) return nextResolve(specifier, context);
    const base = new URL(`./src/${specifier.slice(2)}`, import.meta.url);
    for (const suffix of ['', '.ts', '/index.ts']) {
      if (statSync(fileURLToPath(base) + suffix, { throwIfNoEntry: false })?.isFile()) {
        return nextResolve(base.href + suffix, context);
      }
    }
    return nextResolve(specifier, context);
  },
});
