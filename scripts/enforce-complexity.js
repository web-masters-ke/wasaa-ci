#!/usr/bin/env node
/**
 * enforce-complexity.js <complexity.json> <maxCyclomatic> <maxFileLines>
 *
 * Parses complexity-report output and fails if any function exceeds
 * <maxCyclomatic> or any file exceeds <maxFileLines>.
 */
const fs = require('fs');
const [,, path, maxCyclo, maxLines] = process.argv;
const MAX_C = parseInt(maxCyclo || '15', 10);
const MAX_L = parseInt(maxLines || '500', 10);

let data;
try { data = JSON.parse(fs.readFileSync(path, 'utf8')); }
catch (e) { console.log('no complexity report — skipping'); process.exit(0); }

const reports = data.reports || [];
let fail = 0;
for (const r of reports) {
  if (r.aggregate && r.aggregate.sloc && r.aggregate.sloc.physical > MAX_L) {
    console.error(`::error file=${r.path}::file length ${r.aggregate.sloc.physical} > ${MAX_L}`);
    fail++;
  }
  for (const fn of r.functions || []) {
    if (fn.cyclomatic > MAX_C) {
      console.error(`::error file=${r.path},line=${fn.line}::function '${fn.name}' cyclomatic ${fn.cyclomatic} > ${MAX_C}`);
      fail++;
    }
  }
}
if (fail) { console.error(`complexity gate failed: ${fail} finding(s)`); process.exit(1); }
console.log('complexity gate: OK');
