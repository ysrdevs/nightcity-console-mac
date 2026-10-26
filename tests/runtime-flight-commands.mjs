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
  const metadata = { params: name === 'NCCFlightProbePrepare' ? 1 : 0,
    hash: name === 'NCCFlightInput' ? UINT32 : STRING,
    parameterHash: UINT32, nullParameters: false, nullParameter: false, nullParameterType: false,
    isStatic: false, nullReturn: false, ...overrides };
  return {
    isStatic: metadata.isStatic,
    fn: { name, add(offset) {
      if (offset === 0x30) return { readU32: () => metadata.params };
      assert.equal(offset, 0x28, 'only parameter count/table metadata may be read');
      return { readPointer: () => ({ isNull: () => metadata.nullParameters,
        readPointer: () => ({ isNull: () => metadata.nullParameter,
          readPointer: () => ({ isNull: () => metadata.nullParameterType, hash: metadata.parameterHash }) }) }) };
    } },
    retType: { hash: metadata.hash, isNull: () => metadata.nullReturn },
  };
}

function harness(options = {}) {
  const methods = new Map(['NCCFlightInput', 'NCCFlightProbePrepare', 'NCCFlightProbeValidate',
    'NCCFlightProbeReturn', 'NCCFlightProbeStatus', 'NCCFlightProbeCameraTrace'].map(name => [name, method(name)]));
  const state = { version: '2.5', packet: 512 | 256, player: pointer(0xabc0),
    calls: [], lookups: [], bindings: [], reads: [], logs: [], snapshotReads: 0, snapshots: [], fault: null, ...options };
  const game = pointer(0xdef0);
  const gate = {
    flightInputAvailable: options.exportAvailable !== false,
    binding: options.initialBinding ?? pointer(0),
    flightInput(fn) { state.bindings.push(fn); this.binding = fn; },
    flightInputPacket() {
      ++state.snapshotReads;
      assert.equal(this.binding, methods.get('NCCFlightInput').fn,
        'the exact validated method must be bound before checking native availability');
      if (state.fault === 'input-snapshot') throw Error('INPUT_SNAPSHOT_FAILED');
      state.snapshots.push(state.packet >>> 0);
      return state.packet;
    },
  };
  const context = vm.createContext({
    ensureFlightCapture() {
      if(state.fault === 'capture-setup') throw Error('CAPTURE_SETUP_FAILED');
      state.reads.push('capture-setup');
      if (options.afterCapture) options.afterCapture(state);
    },
    ensureFlightPosition() { if(state.fault === 'position-setup') throw Error('POSITION_SETUP_FAILED'); state.reads.push('position-setup'); },
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
      if (fn.name === 'NCCFlightProbePrepare') {
        assert.deepEqual(Array.from(args), [String(state.snapshots.at(-1))],
          'preparation must receive the exact non-consuming native snapshot as unsigned decimal');
        assert(state.reads.includes('capture-setup') && state.reads.includes('position-setup'),
          'both native gates must be configured before preparation is queued');
      } else assert.equal(args.length, 0, 'diagnostic/return commands remain zero-argument methods');
      assert.notEqual(fn.name, 'NCCFlightInput',
        'command callbacks must not attempt a scripted input round trip: Frida suppresses the same listener');
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
  assert.equal(h.state.snapshotReads, 0);
}
for (const options of [{ missingGate: true }, { exportAvailable: false }]) {
  const h = harness(options);
  assert.throws(() => h.run('toggle'), /input bridge is unavailable/);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.bindings.length, 0);
  assert.equal(h.state.snapshotReads, 0);
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
for (const [action, name] of [['toggle', 'NCCFlightProbePrepare'], ['validate', 'NCCFlightProbeValidate'], ['camera', 'NCCFlightProbeCameraTrace']]) {
  for (const invalid of [null, { params: action === 'toggle' ? 0 : 1 }, { params: 2 }, { hash: UINT32 }, { isStatic: true }, { nullReturn: true }]) {
    const h = harness();
    if (invalid === null) h.methods.delete(name);
    else h.methods.set(name, method(name, invalid));
    assert.throws(() => h.run(action), /unsupported signature/);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.bindings.length, 0);
  }
}
for (const invalid of [{ nullParameters: true }, { nullParameter: true }, { nullParameterType: true }, { parameterHash: STRING }]) {
  const h = harness();
  h.methods.set('NCCFlightProbePrepare', method('NCCFlightProbePrepare', invalid));
  assert.throws(() => h.run('toggle'), /requires one Uint32 input packet/);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.snapshotReads, 0);
  assert.equal(h.state.bindings.length, 0);
}
for (const packet of [0, 1, 256, 256 | 1]) {
  const h = harness({ packet });
  assert.throws(() => h.run('toggle'), /native input is not ready/);
  assert.equal(h.state.calls.length, 0, 'a non-ready native snapshot must not execute a script command');
  assert.equal(h.state.snapshotReads, 1);
  assert(h.gate.binding.isNull(), 'a failed native availability check must disable input binding');
}
for (const [packet, message] of [[512 | 4096, /Return to the game/], [512 | 32768, /counter exhausted/]]) {
  const h = harness({ packet });
  assert.throws(() => h.run('toggle'), message);
  assert.equal(h.state.calls.length, 0);
  assert.equal(h.state.snapshotReads, 1);
  assert.equal(h.gate.binding, h.methods.get('NCCFlightInput').fn,
    'focus rejection must retain input binding for ongoing stop processing');
  h.run('return'); h.run('status');
  assert.deepEqual(h.state.calls.map(call => call.name), ['NCCFlightProbeReturn', 'NCCFlightProbeStatus']);
}
for (const fault of ['input-snapshot']) {
  const h = harness({ fault });
  assert.throws(() => h.run('toggle'), /INPUT_SNAPSHOT_FAILED/);
  assert.equal(h.state.calls.length, 0);
  assert(h.gate.binding.isNull(), 'a throwing native snapshot must disable input binding');
}
for (const [action, expected] of [[undefined, 'NCCFlightProbeStatus'], ['status', 'NCCFlightProbeStatus'],
  ['validate', 'NCCFlightProbeValidate'], ['camera', 'NCCFlightProbeCameraTrace'], ['toggle', 'NCCFlightProbePrepare'],
  ['return', 'NCCFlightProbeReturn'], ['off', 'NCCFlightProbeReturn']]) {
  const h = harness();
  h.run(action);
  assert.deepEqual(h.state.calls.map(call => call.name), [expected]);
  assert.equal(h.state.snapshotReads, 1);
  assert.equal(h.state.logs.at(-1), `[Flight] result:${expected}`);
  assert.equal(h.gate.binding, h.methods.get('NCCFlightInput').fn);
}
for (const packet of [512 | 256, 512 | 3072 | 128, (0x80000000 | 512 | 256) >>> 0, (0xffff0000 | 512) >>> 0]) {
  const h = harness({ packet });
  h.run('toggle');
  assert.deepEqual(h.state.calls[0].args, [String(packet)]);
  assert.equal(h.state.snapshotReads, 1, 'the command samples native input once and never consumes it');
  assert.deepEqual(h.state.lookups, ['NCCFlightInput', 'NCCFlightProbePrepare'],
    'one-click command must not invoke Validate, the input stub, or a collision-filter method');
}
{
  const initial = (7 << 16) | 512 | 256;
  const h = harness({ packet: initial, afterCapture(state) { state.packet = (8 << 16) | 512; } });
  h.run('toggle');
  assert.deepEqual(h.state.calls[0].args, [String(initial)],
    'focus changes during setup must not silently replace the original request epoch');
  assert.equal(h.state.snapshotReads, 1);
}
{
  const h = harness({ fault: 'position-setup' });
  assert.throws(() => h.run('toggle'), /POSITION_SETUP_FAILED/);
  assert.equal(h.state.calls.length, 0, 'position preflight must pass before requesting activation');
  h.run('return'); h.run('status');
  assert.deepEqual(h.state.calls.map(call => call.name), ['NCCFlightProbeReturn', 'NCCFlightProbeStatus'],
    'return and status remain available when position setup fails');
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

console.log('PASS production flight commands: game version, bridge availability, exact RTTI signatures, invalid verbs, current player, fail-closed native snapshot, no callback-origin script input call, String buffers and stable status binding');
console.log('PASS one-click preparation: exact instance String(Uint32), unsigned epoch/settings packet, no mandatory Validate/crouch call, inactive/exhausted rejection, return/status availability and request epoch preserved across setup');
