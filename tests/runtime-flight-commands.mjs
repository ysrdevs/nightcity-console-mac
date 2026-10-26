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
  const metadata = { params: ['NCCFlightProbePrepare', 'NCCFlightProbeResume'].includes(name) ? 1 : 0,
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
  const methods = new Map(['NCCFlightInput', 'NCCFlightProbePrepare', 'NCCFlightProbeResume',
    'NCCFlightProbeStopHere', 'NCCFlightProbeValidate', 'NCCFlightProbeReturn', 'NCCFlightProbeStatus', 'NCCFlightProbeCameraTrace'].map(name => [name, method(name)]));
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
      if (['NCCFlightProbePrepare', 'NCCFlightProbeResume'].includes(fn.name)) {
        assert.deepEqual(Array.from(args), [String(state.snapshots.at(-1))],
          'Start/Resume must receive the exact non-consuming native snapshot as unsigned decimal');
        assert(state.reads.includes('capture-setup') && state.reads.includes('position-setup'),
          'both native gates must be configured before Start/Resume is queued');
      } else assert.equal(args.length, 0, 'diagnostic/cleanup commands remain zero-argument methods');
      assert.notEqual(fn.name, 'NCCFlightInput',
        'command callbacks must not attempt a scripted input round trip: Frida suppresses the same listener');
      if (state.fault === 'target-call') throw Error('TARGET_CALL_FAILED');
      assert.equal(resultSize, 0x20, 'String results need the complete 32-byte return buffer');
      return { string: state.targetResult ?? `result:${fn.name}` };
    },
    readRedString: buffer => buffer.string,
    log: line => state.logs.push(line),
  });
  vm.runInContext(flight, context);
  return { state, gate, methods, run: action => context.doFlight(action) };
}

const armingActions = [['start', 'NCCFlightProbePrepare'], ['resume', 'NCCFlightProbeResume'],
  ['toggle', 'NCCFlightProbePrepare']];
const diagnosticActions = [['validate', 'NCCFlightProbeValidate'], ['camera', 'NCCFlightProbeCameraTrace']];
const cleanupActions = [['stop', 'NCCFlightProbeStopHere'], ['off', 'NCCFlightProbeStopHere'],
  ['return', 'NCCFlightProbeReturn'], ['status', 'NCCFlightProbeStatus'], [undefined, 'NCCFlightProbeStatus']];
const inputActions = [...armingActions, ...diagnosticActions];
const allActions = [...inputActions, ...cleanupActions];

function assertNoInputWork(h) {
  assert.equal(h.state.bindings.length, 0, 'cleanup/status must never change an existing input binding');
  assert.equal(h.state.snapshotReads, 0, 'cleanup/status must not read or consume native input');
  assert(!h.state.lookups.includes('NCCFlightInput'), 'cleanup/status must not require input RTTI');
  assert(!h.state.reads.includes('capture-setup') && !h.state.reads.includes('position-setup'),
    'cleanup/status must not require native movement setup');
}

for (const version of ['2.3.1', '2.5.0', 'unknown']) {
  for (const [action] of allActions) {
    const h = harness({ version });
    assert.throws(() => h.run(action), /requires game 2\.5\.0/);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.bindings.length, 0);
    assert.equal(h.state.snapshotReads, 0);
  }
}
for (const [action] of inputActions) {
  for (const options of [{ missingGate: true }, { exportAvailable: false }]) {
    const h = harness(options);
    assert.throws(() => h.run(action), /input bridge is unavailable/);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.bindings.length, 0);
    assert.equal(h.state.snapshotReads, 0);
  }
  for (const invalid of [null, { params: 1 }, { hash: STRING }, { isStatic: true }, { nullReturn: true }]) {
    const h = harness({ initialBinding: pointer(0x7777) });
    if (invalid === null) h.methods.delete('NCCFlightInput');
    else h.methods.set('NCCFlightInput', method('NCCFlightInput', invalid));
    assert.throws(() => h.run(action), /input signature differs/);
    assert(h.gate.binding.isNull(), 'invalid input RTTI must remove a previous native binding');
    assert.equal(h.state.calls.length, 0);
  }
}
for (const [action] of allActions) {
  for (const player of [null, pointer(0)]) {
    const h = harness({ player });
    assert.throws(() => h.run(action), /Load a save/);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.bindings.length, 0);
  }
}
for (const action of ['enable', 'constructor', 'toString', '__proto__', 'hasOwnProperty']) {
  const h = harness();
  assert.throws(() => h.run(action), /Use flight/);
  assert.equal(h.state.calls.length, 0, 'invalid verbs must not execute a flight method');
  assert.equal(h.state.reads.length, 0, 'invalid verbs must not enter the engine for player lookup');
  assert.equal(h.state.lookups.length, 0, 'invalid verbs must not resolve RTTI');
  assert.equal(h.state.bindings.length, 0, 'invalid verbs must preserve any active binding');
}
for (const [action, name] of allActions) {
  const arming = armingActions.some(([verb]) => verb === action);
  for (const invalid of [null, { params: arming ? 0 : 1 }, { params: 2 }, { hash: UINT32 }, { isStatic: true }, { nullReturn: true }]) {
    const h = harness();
    if (invalid === null) h.methods.delete(name);
    else h.methods.set(name, method(name, invalid));
    assert.throws(() => h.run(action), /unsupported signature/);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.bindings.length, 0);
  }
}
for (const [action, name] of armingActions) {
  for (const invalid of [{ nullParameters: true }, { nullParameter: true }, { nullParameterType: true }, { parameterHash: STRING }]) {
    const h = harness();
    h.methods.set(name, method(name, invalid));
    assert.throws(() => h.run(action), /requires one Uint32 input packet/);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.snapshotReads, 0);
    assert.equal(h.state.bindings.length, 0);
  }
}
for (const [action] of inputActions) {
  for (const packet of [0, 1, 256, 256 | 1]) {
    const h = harness({ packet });
    assert.throws(() => h.run(action), /native input is not ready/);
    assert.equal(h.state.calls.length, 0, 'a non-ready native snapshot must not execute an input-dependent command');
    assert.equal(h.state.snapshotReads, 1);
    assert(h.gate.binding.isNull(), 'a failed native availability check must disable input binding');
  }
  const h = harness({ fault: 'input-snapshot' });
  assert.throws(() => h.run(action), /INPUT_SNAPSHOT_FAILED/);
  assert.equal(h.state.calls.length, 0);
  assert(h.gate.binding.isNull(), 'a throwing native snapshot must disable input binding');
}
for (const [action] of armingActions) {
  for (const [packet, message] of [[512 | 4096, /Return to the game/], [512 | 32768, /counter exhausted/]]) {
    const h = harness({ packet });
    assert.throws(() => h.run(action), message);
    assert.equal(h.state.calls.length, 0);
    assert.equal(h.state.snapshotReads, 1);
    assert.equal(h.gate.binding, h.methods.get('NCCFlightInput').fn,
      'focus rejection must retain input binding for ongoing stop processing');
    for (const [cleanup] of cleanupActions) h.run(cleanup);
    assert.deepEqual(h.state.calls.map(call => call.name), cleanupActions.map(([, name]) => name));
    assert.equal(h.state.snapshotReads, 1, 'cleanup/status must not add input reads after focus rejection');
  }
}
for (const [action, expected] of allActions) {
  const h = harness();
  h.run(action);
  assert.deepEqual(h.state.calls.map(call => call.name), [expected]);
  assert.equal(h.state.logs.at(-1), `[Flight] result:${expected}`);
  if (inputActions.some(([verb]) => verb === action)) {
    assert.equal(h.state.snapshotReads, 1);
    assert.equal(h.gate.binding, h.methods.get('NCCFlightInput').fn);
    assert.equal(h.state.reads.includes('position-setup'), armingActions.some(([verb]) => verb === action));
  } else assertNoInputWork(h);
}
for (const [action, name] of armingActions) {
  for (const packet of [512 | 256, 512 | 3072 | 128, (0x80000000 | 512 | 256) >>> 0, (0xffff0000 | 512) >>> 0]) {
    const h = harness({ packet });
    h.run(action);
    assert.deepEqual(h.state.calls[0].args, [String(packet)]);
    assert.equal(h.state.snapshotReads, 1, 'an explicit request samples native input once and never consumes it');
    assert.deepEqual(h.state.lookups, ['NCCFlightInput', name],
      'Start/Resume must not invoke Validate, the input stub, or a collision-filter method');
  }
  const initial = (7 << 16) | 512 | 256;
  const h = harness({ packet: initial, afterCapture(state) { state.packet = (8 << 16) | 512; } });
  h.run(action);
  assert.deepEqual(h.state.calls[0].args, [String(initial)],
    'focus changes during setup must not silently replace the original request epoch');
  assert.equal(h.state.snapshotReads, 1);
}
for (const [action] of armingActions) {
  for (const [fault, message] of [['capture-setup', /CAPTURE_SETUP_FAILED/], ['position-setup', /POSITION_SETUP_FAILED/]]) {
    const h = harness({ fault });
    assert.throws(() => h.run(action), message);
    assert.equal(h.state.calls.length, 0, 'native preflight must pass before requesting movement');
    const reads = h.state.snapshotReads;
    for (const [cleanup] of cleanupActions) h.run(cleanup);
    assert.deepEqual(h.state.calls.map(call => call.name), cleanupActions.map(([, name]) => name));
    assert.equal(h.state.snapshotReads, reads, 'failed setup must not make cleanup/status depend on input');
  }
}
for (const [action, expected] of cleanupActions) {
  for (const options of [{ missingGate: true }, { exportAvailable: false }, { packet: 0 },
    { packet: 512 | 4096 | 32768 }, { fault: 'input-snapshot' }, { fault: 'capture-setup' }, { fault: 'position-setup' }]) {
    const previous = pointer(0x7777);
    const h = harness({ ...options, initialBinding: previous });
    h.methods.delete('NCCFlightInput');
    h.run(action);
    assert.deepEqual(h.state.calls.map(call => call.name), [expected]);
    assertNoInputWork(h);
    assert.equal(h.gate.binding, previous, 'cleanup/status leave an existing native binding untouched');
    assert.deepEqual(h.state.lookups, [expected]);
    assert.deepEqual(h.state.reads, ['game', 'player'], 'cleanup/status still use the current player');
  }
}
{
  const h = harness();
  h.run('start');
  const bound = h.gate.binding;
  const snapshots = h.state.snapshotReads;
  const bindings = h.state.bindings.length;
  h.run('stop'); h.run('return'); h.run('status'); h.run('status');
  assert.equal(h.gate.binding, bound);
  assert.equal(h.state.bindings.length, bindings, 'cleanup/status never transiently unbind active input');
  assert.equal(h.state.snapshotReads, snapshots, 'cleanup/status must not create per-command input polling');
}
for (const [action] of allActions) {
  const h = harness({ fault: 'target-call' });
  assert.throws(() => h.run(action), /TARGET_CALL_FAILED/);
  assert.equal(h.state.calls.length, 1, 'a throwing script command must never be retried automatically');
  assert.equal(h.state.logs.length, 0, 'a throwing script command must not report success');
}
for (const [action] of armingActions) {
  const h = harness({ targetResult: 'refused: session is not eligible' });
  h.run(action);
  assert.equal(h.state.calls.length, 1, 'Start/Resume never retry a script refusal');
  assert.equal(h.state.logs.at(-1), '[Flight] refused: session is not eligible');
}

console.log('PASS production flight commands: exact version/RTTI/current player, explicit Start/Resume/Stop here/Return/Status, narrow aliases, fail-closed input, unsigned request epoch and native setup ordering');
console.log('PASS cleanup availability: Stop/Return/Status require no input export, RTTI, snapshot or movement setup; retain current-player/signature checks, existing binding and authoritative script result without retry');
