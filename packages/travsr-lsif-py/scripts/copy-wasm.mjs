// Put the two grammar/runtime .wasm files beside the compiled emitter.
//
// walker.ts loads them from its own directory, which is the one layout that
// holds in both places the emitter runs: dist/ in this checkout, and
// travsr-lib/ beside the installed binary, where there is no node_modules to
// resolve through.
import { copyFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
for (const spec of ['web-tree-sitter/tree-sitter.wasm', 'tree-sitter-python/tree-sitter-python.wasm']) {
  copyFileSync(require.resolve(spec), join('dist', basename(spec)));
}
