import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '../..');
const output = path.join(root, 'Resources/Markdown');
await fs.mkdir(output, {recursive: true});
await build({entryPoints: [path.join(import.meta.dirname, 'sticky.mjs')], outfile: path.join(output, 'sticky.js'), bundle: true, format: 'iife', target: 'safari16', minify: true, legalComments: 'external'});
await fs.copyFile(path.join(import.meta.dirname, 'node_modules/katex/dist/katex.min.css'), path.join(output, 'katex.min.css'));
await fs.cp(path.join(import.meta.dirname, 'node_modules/katex/dist/fonts'), path.join(output, 'fonts'), {recursive: true});
// Ship all installed production dependency licenses, including the Mermaid dependency graph.
const licenses = [];
async function visit(directory) {
  for (const entry of await fs.readdir(directory, {withFileTypes: true})) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const packagePath = path.join(directory, entry.name);
    if (entry.name.startsWith('@')) { await visit(packagePath); continue; }
    try {
      const pkg = JSON.parse(await fs.readFile(path.join(packagePath, 'package.json'), 'utf8'));
      for (const name of await fs.readdir(packagePath)) {
        if (/^(?:licen[sc]e|copying|notice)(?:[. -]|$)/i.test(name)) {
          const filePath = path.join(packagePath, name);
          if ((await fs.stat(filePath)).isFile()) licenses.push(`\n===== ${pkg.name}@${pkg.version}: ${name} =====\n${await fs.readFile(filePath, 'utf8')}`);
        }
      }
      try { await visit(path.join(packagePath, 'node_modules')); } catch {}
    } catch {}
  }
}
await visit(path.join(import.meta.dirname, 'node_modules'));
await fs.writeFile(path.join(output, 'THIRD-PARTY-LICENSES.txt'), licenses.join('\n'));
console.log(`Built ${output}`);
