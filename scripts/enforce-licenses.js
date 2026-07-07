#!/usr/bin/env node
/**
 * enforce-licenses.js <licenses-node.json> <allowlist.json>
 *
 * Reads license-checker output (JSON), checks each package license against
 * the allow/deny list. Exits 1 on any denied license.
 */
const fs = require('fs');
const [,, licensesPath, allowlistPath] = process.argv;
if (!licensesPath || !allowlistPath) {
  console.error('usage: enforce-licenses.js <licenses.json> <allowlist.json>');
  process.exit(2);
}
const licenses = JSON.parse(fs.readFileSync(licensesPath, 'utf8'));
const { allowed, denied } = JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));

const isDenied = (l) => denied.some(d => new RegExp('^' + d.replace(/\*/g,'.*') + '$', 'i').test(l));
const isAllowed = (l) => allowed.some(a => a.toLowerCase() === l.toLowerCase());

let fail = 0;
for (const [pkg, meta] of Object.entries(licenses)) {
  const raw = meta.licenses || 'UNKNOWN';
  const list = Array.isArray(raw) ? raw : String(raw).split(/\s+OR\s+|,\s*/i);
  const passes = list.some(isAllowed);
  const blocked = list.some(isDenied);
  if (blocked) {
    console.error(`::error::license DENIED: ${pkg} (${raw})`);
    fail++;
  } else if (!passes) {
    console.error(`::error::license UNAPPROVED: ${pkg} (${raw}) — request Legal review or add to allowlist`);
    fail++;
  }
}
if (fail) {
  console.error(`\nlicense enforcement failed: ${fail} package(s)`);
  process.exit(1);
}
console.log('license enforcement: OK');
