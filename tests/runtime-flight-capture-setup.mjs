import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Execute the actual setup guard. No real engine or hook is used by this test.
const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const begin = source.indexOf('function ensureFlightCapture() {');
const end = source.indexOf('function doFlight(action)', begin);
assert(begin >= 0 && end > begin);
const code = source.slice(begin, end);
const hashes = { Variant: 0x101n, physicsSimulationFilter: 0x102n, physicsStateValue: 0x103n };
const UINT32 = '0x3d2e9dd9e3c28d8c';
const fingerprint = 'ff4301d1f65702a9f44f03a9fd7b04a9fd030191f30302aa';
function type(hash, size, alignment) {
  return { hash, size, alignment, isNull: () => false,
    readPointer: () => ({ add: offset => ({ readPointer: () => ({ offset }) }) }) };
}
function method(retType, isStatic = false) {
  return { retType, isStatic, params: 0, fn: null };
}
function fixture() {
  const methods = {
    NCCFlightCaptureBegin: method(type(UINT32, 4, 4)),
    NCCFlightCaptureEnd: method(type('0x101', 24, 8)),
    ZERO: method(type('0x102', 16, 8), true),
  };
  for (const [name, value] of Object.entries(methods)) {
    value.fn = { name, add: offset => { assert.equal(offset, 0x30); return { readU32: () => value.params }; } };
  }
  const state = { bytes: fingerprint, enumValue: 32, hooks: [], bindings: [], logs: [], failAttach: false };
  const address = { readByteArray: count => { assert.equal(count, 24); return Uint8Array.from(Buffer.from(state.bytes, 'hex')).buffer; } };
  const gate = { flightCaptureAvailable: true, flightCaptureMethods: (...args) => state.bindings.push(args) };
  const context = vm.createContext({
    flightCaptureHook: null, executorGate: gate, T_U32: UINT32,
    fnv: name => { assert(name in hashes); return hashes[name]; },
    nameOf: value => value.hash,
    resolveAny(classes, name) {
      assert(Array.from(classes).includes(name === 'ZERO' ? 'physicsSimulationFilter' : 'gamestateMachineGameScriptInterface'));
      return methods[name];
    },
    resolveEnumByTypeHash(hash, name) {
      assert.equal(hash, '0x103'); assert.equal(name, 'SimulationFilter');
      return state.enumValue === null ? null : { equals: expected => state.enumValue === expected };
    },
    uint64: value => value,
    NativeFunction: function (pointer, result, args) {
      assert.equal(result, 'uint'); assert.deepEqual(Array.from(args), ['pointer']);
      assert([0x18, 0x20].includes(pointer.offset));
      return value => pointer.offset === 0x18 ? value.size : value.alignment;
    },
    base: { add(offset) { assert.equal(offset, 0x24c0304); return address; } },
    createFlightCaptureHook(...args) {
      if (state.failAttach) throw Error('ATTACH_FAILED');
      state.hooks.push(args); return { installed: true };
    },
    log: line => state.logs.push(line),
  });
  vm.runInContext(code, context);
  return { methods, state, gate, context, run: () => context.ensureFlightCapture() };
}

for (const mutate of [
  f => { f.gate.flightCaptureAvailable = false; },
  f => { delete f.methods.NCCFlightCaptureBegin; },
  f => { f.methods.NCCFlightCaptureBegin.params = 1; },
  f => { f.methods.NCCFlightCaptureBegin.isStatic = true; },
  f => { f.methods.NCCFlightCaptureEnd.retType.hash = UINT32; },
  f => { f.methods.NCCFlightCaptureEnd.retType.size = 16; },
  f => { f.methods.NCCFlightCaptureEnd.retType.alignment = 16; },
  f => { f.methods.ZERO.isStatic = false; },
  f => { f.methods.ZERO.retType.hash = '0xffff'; },
  f => { f.methods.ZERO.retType.size = 24; },
  f => { f.methods.ZERO.retType.alignment = 4; },
  f => { f.state.enumValue = null; },
  f => { f.state.enumValue = 31; },
  f => { f.state.bytes = '00'.repeat(24); },
  f => { f.state.failAttach = true; },
]) {
  const f = fixture(); mutate(f);
  assert.throws(f.run);
  assert.equal(f.state.hooks.length, 0, 'rejected ABI or fingerprint must not install a hook');
  assert.equal(f.state.bindings.length, 0, 'failed setup must not publish script bindings');
  assert.equal(f.context.flightCaptureHook, null);
}
{
  const f = fixture(); f.run(); f.run();
  assert.equal(f.state.hooks.length, 1, 'repeat validation reuses one capture hook');
  assert.equal(f.state.bindings.length, 1);
  assert.deepEqual(f.state.bindings[0], [f.methods.NCCFlightCaptureBegin.fn, f.methods.NCCFlightCaptureEnd.fn]);
  assert.equal(f.state.hooks[0][1], f.methods.ZERO.retType);
  assert.deepEqual(f.state.hooks[0].slice(2), [16, 8, 32]);
}
console.log('PASS capture setup: script signatures, exact RTTI layouts, enum and code fingerprint, hook failure isolation, single installation');
