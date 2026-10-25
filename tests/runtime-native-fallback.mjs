import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const installation = source.split('// BEGIN EXECUTOR LISTENER')[1].split('// END EXECUTOR LISTENER')[0];
for (const legacy231 of [true, false]) {
  let callbacks, attemptedNative = 0;
  const dispatched = [], depthByTid = {};
  const context = {
    isGame231: () => legacy231,
    createExecutorGate() { attemptedNative++; throw Error('unsupported CModule fixture'); },
    Interceptor: { attach(address, value) { callbacks = value; } },
    execAddr: 'executor', pendingQ: ['queued command'], obsCount: 0, depthByTid,
    captureExecutorContext: (fn, owner) => owner ? 1 : 0,
    drainExecutorCommand(owner, depth) { if (depth === 0) dispatched.push(owner); },
    log() {},
  };
  vm.runInNewContext('let executorGate = null;' + installation, context);
  assert.equal(attemptedNative, legacy231 ? 0 : 1);
  const outerA = { threadId: 1 }, innerA = { threadId: 1 }, outerB = { threadId: 2 };
  callbacks.onEnter.call(outerA, ['fn', 'ownerA', 'frame']);
  callbacks.onEnter.call(innerA, ['fn', 'nestedOwnerA', 'frame']);
  callbacks.onEnter.call(outerB, ['fn', 'ownerB', 'frame']);
  callbacks.onLeave.call(innerA);
  assert.deepEqual(dispatched, []);
  callbacks.onLeave.call(outerB);
  callbacks.onLeave.call(outerA);
  assert.deepEqual(dispatched, ['ownerB', 'ownerA']);
  assert.deepEqual(depthByTid, {});
}
console.log('2.3.1 compatibility and unsupported native-gate fallback preserve per-thread nesting and command dispatch.');
