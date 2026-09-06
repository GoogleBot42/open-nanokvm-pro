// Off-device unit test for the #69 detector's discriminator.
//
// The browser half of the check (MediaStreamTrackProcessor -> VideoFrame ->
// copyTo) needs a real Chromium; what IS decidable off-device is how its
// outcome is classified, which is the whole verdict logic. The test lifts the
// classifier's exact source text out of the hook and runs THAT -- no second
// copy to drift.
//
// Run: nix shell nixpkgs#nodejs --command node predicate-test.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hook = resolve(here, '../../../../web/src/hooks/useUndrawableVideoDetector.ts');

const src = readFileSync(hook, 'utf8');
const match = src.match(/export function classifyCopyFailure[\s\S]*?\n}\n/);
if (!match) throw new Error('classifyCopyFailure not found in ' + hook);

const js = match[0]
  .replace('export function', 'function')
  .replace(': unknown', '')
  .replace("): Exclude<Verdict, 'readable'>", ')')
  .replace('as { name?: string } | null', '');

const classifyCopyFailure = new Function(`${js}\nreturn classifyCopyFailure;`)();

// What Chromium throws from VideoFrame.copyTo() with the Vulkan backend on:
// InvalidStateError "Failed to read VideoFrame data". Everything else says
// nothing about whether the browser paints, so it must be inconclusive.
const invalidState = Object.assign(new Error('Failed to read VideoFrame data'), {
  name: 'InvalidStateError'
});

const cases = [
  ['a) InvalidStateError from copyTo (the measured failure)', invalidState, 'unreadable'],
  ['b) TypeError (API misuse)', new TypeError('bad'), 'inconclusive'],
  [
    'c) SecurityError (cross-origin media)',
    Object.assign(new Error('x'), { name: 'SecurityError' }),
    'inconclusive'
  ],
  [
    'd) NotSupportedError',
    Object.assign(new Error('x'), { name: 'NotSupportedError' }),
    'inconclusive'
  ],
  ['e) a thrown string', 'boom', 'inconclusive'],
  ['f) null', null, 'inconclusive'],
  ['g) undefined', undefined, 'inconclusive']
];

let failed = 0;
for (const [name, err, want] of cases) {
  const got = classifyCopyFailure(err);
  const ok = got === want;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}: ${got} (want ${want})`);
}

console.log(failed === 0 ? `\nall ${cases.length} cases pass` : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
