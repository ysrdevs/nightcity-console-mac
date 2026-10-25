import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Run the actual command validator, with only the RTTI/engine boundary mocked.
// Native result-buffer isolation is exercised separately by runtime-native-gates.py.
const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const start = source.indexOf('function doFlight(action) {');
const end = source.indexOf('function resolveGlobal(', start);
assert(start >= 0 && end > start, 'production flight function boundaries must exist');
const flight = source.slice(start, end);
const UINT32 = '0x3d2e9dd9e3c28d8c';
const STRING = '0xfeed1234';

function pointer(value) {
  return { value, isNull() { return value === 0; } };
}

function method(name, overrides = {}) {
  const metadata = { params: 0, hash: name === 'NCCFlightInput' ? UINT32 : STRING,
    isStatic: false, nullReturn: false, ...overrides };
  return {
    isStatic: metadata.isStatic,
    fn: { name, add(offset) {
      assert.equal(offset, 0x30, 'only the validated parameter-count field is read');
      return { readU32: () => metadata.params };
    } },
    retType: { hash: metadata.hash, isNull: () => metadata.nullReturn },
  };
}

function harness(options = {}) {
  const methods = new Map(['NCCFlightInput', 'NCCFlightProbeToggle',
    'NCCFlightProbeReturn', 'NCCFlightProbeStatus'].map(name => [name, method(name)]));
  const state = { version: '2.5', packet: 512 | 256, player: pointer(0xabc0),
    calls: [], lookups: [], bindings: [], reads: [], logs: [], fault: null, ...options };
  const game = pointer(0xdef0);
  const gate = {
    flightInputAvailable: options.exportAvailable !== false,
    binding: options.initialBinding ?? pointer(0),
    flightInput(fn) { state.bindings.push(fn); this.binding = fn; },
  };
  const context = vm.createContext({
    getGameVersion: () => state.version,
    executorGate: options.missingGate ? null : gate,
    T_U32: UINT32,
    resolveAny(classes, name) {
      assert.deepEqual(Array.from(classes), ['gamePlayerPuppet', 'PlayerPuppet']);
      assert.equal(typeof name, 'string', 'a command must never resolve an inherited object method');
      state.lookups.push(name);
      return methods.get(name) ?? null;
    },
    nameOf: type => type.hash,
    fnv(name) { assert.equal(name, 'String'); return BigInt(STRING); },
    ptr: pointer,
    getGI() { state.reads.push('game'); return game; },
    getPlayerViaSystem(gi) { assert.equal(gi, game); state.reads.push('player'); return state.player; },
    callFunc(fn, owner, type, args, resultSize) {
      state.calls.push({ name: fn.name, owner, type, args: Array.from(args), resultSize });
      assert.equal(owner, state.player, 'calls must use the authoritative current player');
      assert.equal(args.length, 0, 'all prototype commands are zero-argument methods');
      if (fn.name === 'NCCFlightInput') {
        if (state.fault === 'input-call') throw Error('INPUT_CALL_FAILED');
        assert.equal(gate.binding, fn, 'native method must be bound before its round trip');
        return { readU32() {
          if (state.fault === 'input-read') throw Error('INPUT_READ_FAILED');
          return state.packet;
        } };
      }
      if (state.fault === 'target-call') throw Error('TARGET_CALL_FAILED');
      assert.equal(resultSize, 0x20, 'String results need the complete 32-byte return buffer');
      return { string: `result:${fn.name}` };
    },
    readRedString: buffer => buffer.string,
    log: line => state.logs.push(line),
  });
  vm.runInContext(flight, context);
  return { state, gate, methods, run: action => context.doFlight(action) };
}

for (const version of ['2.3.1', '2.5.0', 'unknown']) {
  const h = harness({ version });
  assert.throws(() => h.run('toggle'), /requires game 2\.5\.0/);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.bindings.length, 0);
}
for (const options of [{ missingGate: true }, { exportAvailable: false }]) {
  const h = harness(options);
  assert.throws(() => h.run('toggle'), /input bridge is unavailable/);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.bindings.length, 0);
}

for (const invalid of [null, { params: 1 }, { hash: STRING }, { isStatic: true }, { nullReturn: true }]) {
  const h = harness({ initialBinding: pointer(0x7777) });
  if (invalid === null) h.methods.delete('NCCFlightInput');
  else h.methods.set('NCCFlightInput', method('NCCFlightInput', invalid));
  assert.throws(() => h.run('toggle'), /input signature differs/);
  assert(h.gate.binding.isNull(), 'invalid input RTTI must remove a previous native binding');
  assert.equal(h.state.calls.length, 0);
}
for (const player of [null, pointer(0)]) {
  const h = harness({ player });
  assert.throws(() => h.run('toggle'), /Load a save/);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.bindings.length, 0);
}
for (const action of ['enable', 'constructor', 'toString', '__proto__', 'hasOwnProperty']) {
  const h = harness();
  assert.throws(() => h.run(action), /Use flight/);
  assert.equal(h.state.calls.length, 0, 'invalid verbs must not execute a flight method');
  assert.equal(h.state.reads.length, 0, 'invalid verbs must not enter the engine for player lookup');
  assert.equal(h.state.bindings.length, 0, 'invalid verbs must preserve any active binding');
}
for (const invalid of [null, { params: 1 }, { hash: UINT32 }, { isStatic: true }, { nullReturn: true }]) {
  const h = harness();
  if (invalid === null) h.methods.delete('NCCFlightProbeToggle');
  else h.methods.set('NCCFlightProbeToggle', method('NCCFlightProbeToggle', invalid));
  assert.throws(() => h.run('toggle'), /unsupported signature/);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.bindings.length, 0);
}
for (const packet of [0, 1, 256, 256 | 1]) {
  const h = harness({ packet });
  assert.throws(() => h.run('toggle'), /native round trip/);
  assert.deepEqual(h.state.calls.map(call => call.name), ['NCCFlightInput']);
  assert(h.gate.binding.isNull(), 'a failed round trip must disable native input binding');
}
for (const fault of ['input-call', 'input-read']) {
  const h = harness({ fault });
  assert.throws(() => h.run('toggle'), /INPUT_(CALL|READ)_FAILED/);
  assert(h.gate.binding.isNull(), 'a throwing input round trip must disable native input binding');
}
for (const [action, expected] of [[undefined, 'NCCFlightProbeStatus'], ['status', 'NCCFlightProbeStatus'],
  ['toggle', 'NCCFlightProbeToggle'], ['return', 'NCCFlightProbeReturn'], ['off', 'NCCFlightProbeReturn']]) {
  const h = harness();
  h.run(action);
  assert.deepEqual(h.state.calls.map(call => call.name), ['NCCFlightInput', expected]);
  assert.equal(h.state.logs.at(-1), `[Flight] result:${expected}`);
  assert.equal(h.gate.binding, h.methods.get('NCCFlightInput').fn);
}
{
  const h = harness();
  h.run('toggle');
  const bound = h.gate.binding;
  h.run('status'); h.run('status');
  assert.equal(h.gate.binding, bound);
  assert(h.state.bindings.every(binding => binding === bound),
    'status must never transiently unbind active input between method calls');
}

console.log('PASS production flight commands: game version, bridge availability, exact RTTI signatures, invalid verbs, current player, fail-closed round trip, String buffers and stable status binding');
