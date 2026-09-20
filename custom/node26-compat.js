// Node 26 ESM/CJS compatibility shim, applied at image build time.
// See custom/build.py -> inject_node26_compat() for the full rationale.
//
// Node 26 loads an EXTENSIONLESS file inside a package declaring "type":"module"
// as ESM. yargs 17.x exports["./yargs"].require points at such a file, whose body
// is CommonJS -> "require is not defined in ES module scope". Give it a .cjs
// extension (always CommonJS) and repoint the export. Same file body, so the
// shim's behaviour is unchanged.
const fs = require('fs');
const path = require('path');
const base = '/opt/runners/task-runner-javascript/node_modules/.pnpm';
let patched = 0, scanned = 0;
for (const d of fs.readdirSync(base)) {
  if (!/^yargs@/.test(d)) continue;
  scanned++;
  const pkgDir = path.join(base, d, 'node_modules', 'yargs');
  const pjPath = path.join(pkgDir, 'package.json');
  if (!fs.existsSync(pjPath)) continue;
  const pj = JSON.parse(fs.readFileSync(pjPath, 'utf8'));
  if (pj.type !== 'module' || !pj.exports || !pj.exports['./yargs']) continue;
  const shim = path.join(pkgDir, 'yargs');
  if (!fs.existsSync(shim)) continue;
  fs.copyFileSync(shim, path.join(pkgDir, 'yargs.cjs'));
  pj.exports['./yargs'] = JSON.parse(
    JSON.stringify(pj.exports['./yargs']).split('"./yargs"').join('"./yargs.cjs"'));
  fs.writeFileSync(pjPath, JSON.stringify(pj, null, 2));
  console.log('node26-compat: patched ' + d);
  patched++;
}
console.log('node26-compat: scanned ' + scanned + ' yargs package(s), patched ' + patched);
// Not fatal when 0: a future yargs may not need it. The real verdict is the
// EXTERNAL-GATE step that follows, which fails the build if anything cannot load.
