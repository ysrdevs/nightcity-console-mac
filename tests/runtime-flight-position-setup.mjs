import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Execute the production setup guard, mocking only RTTI, memory and native
// exports. Native scope/write behavior has its own host and sanitizer fixtures.
const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const begin = source.indexOf('function ensureFlightPosition() {');
const end = source.indexOf('function doFlight(action)', begin);
assert(begin >= 0 && end > begin, 'production position setup boundaries must exist');
const code = source.slice(begin, end);
const BOOL = '0xf7bdd5a7c820889d';
const hashes = { Vector3: 0x201n, physicsStateValue: 0x202n };
const helpers = new Map([
  [0x4582ff8, '08bc02f008c12d91080140f9e103002ae00308aa5008ff17'],
  [0x458697c, 'f657bda9f44f01a9fd7b02a9fd830091f30300aaf403012a'],
  [0x4585148, 'ffc300d1f44f01a9fd7b02a9fd830091e30302aae60301aa'],
  [0x45868d8, '010440f9410100b4f44fbea9fd7b01a9fd430091f30300aa'],
  [0x4586a2c, 'c0035fd6'],
  [0x45836c4, 'ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f30301aa'],
]);

function type(hash, size, alignment) {
  return {
    hash, size, alignment, null: false,
    isNull() { return this.null; },
    readPointer: () => ({ add: offset => ({ readPointer: () => ({ kind: 'measure', offset }) }) }),
  };
}

function fixture() {
  const vectorType = type('0x201', 12, 4);
  const method = { isStatic: false, params: 1, paramsNull: false, parameterNull: false,
    vectorType, retType: type(BOOL, 1, 1) };
  method.fn = {
    add(offset) {
      if (offset === 0x30) return { readU32: () => method.params };
      assert.equal(offset, 0x28, 'only the parameter-array metadata field is read');
      return { readPointer: () => ({
        isNull: () => method.paramsNull,
        readPointer: () => ({ readPointer() {
          if (method.parameterNull) throw Error('NULL_PARAMETER_METADATA');
          return method.vectorType;
        } }),
      }) };
    },
  };
  const state = { method, bytes: new Map(helpers), reads: [], lookups: 0, exports: [], configurations: [],
    bindings: [], logs: [], events: [], enumValue: 1, exportPresent: true,
    accepted: true, configureThrows: false, bindThrows: false, unreadableOffset: null };
  const addresses = new Map([...helpers].map(([offset]) => [offset, {
    offset,
    readByteArray(count) {
      const expectedLength = helpers.get(offset).length / 2;
      assert.equal(count, expectedLength, `helper ${offset.toString(16)} must validate its entire fingerprint`);
      state.reads.push({ offset, count });
      if (state.unreadableOffset === offset) throw Error('UNREADABLE_HELPER');
      return Uint8Array.from(Buffer.from(state.bytes.get(offset), 'hex')).buffer;
    },
  }]));
  const configureExport = { kind: 'configure' };
  let context;
  const gate = {
    positionBridgeAvailable: true,
    positionMethod(fn) {
      assert.equal(context.positionBridgeReady, false, 'ready must not precede publishing the exact method');
      if (state.bindThrows) throw Error('BIND_FAILED');
      state.events.push('bind');
      state.bindings.push(fn);
    },
  };
  context = vm.createContext({
    positionBridgeReady: false,
    executorGate: gate,
    flightCaptureHook: { positionBridgeAvailable: true },
    T_BOOL: BOOL,
    fnv(name) { assert(name in hashes); return hashes[name]; },
    nameOf(value) { return !value || value.isNull() ? null : value.hash; },
    resolveAny(classes, name) {
      assert.deepEqual(Array.from(classes), ['gamestateMachineGameScriptInterface', 'StateGameScriptInterface']);
      assert.equal(name, 'NCCFlightWritePosition');
      ++state.lookups;
      return state.method;
    },
    resolveEnumByTypeHash(hash, name) {
      assert.equal(hash, '0x202'); assert.equal(name, 'Position');
      return state.enumValue === null ? null : { equals: value => state.enumValue === value };
    },
    uint64: value => value,
    base: { add(offset) { assert(addresses.has(offset), 'only the six reviewed helpers may be read'); return addresses.get(offset); } },
    Module: { findGlobalExportByName(name) {
      assert.equal(name, 'nightcity_flight_position_configure');
      state.exports.push(name);
      return state.exportPresent ? configureExport : null;
    } },
    NativeFunction: function (pointer, result, args, options) {
      assert.equal(result, 'uint');
      if (pointer.kind === 'measure') {
        assert.deepEqual(Array.from(args), ['pointer']);
        assert([0x18, 0x20].includes(pointer.offset));
        return value => pointer.offset === 0x18 ? value.size : value.alignment;
      }
      assert.equal(pointer, configureExport);
      assert.deepEqual(Array.from(args), ['pointer', 'uint', 'uint', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
      assert.equal(options.scheduling, 'exclusive');
      assert.equal(options.traps, 'none');
      return (...values) => {
        assert.equal(context.positionBridgeReady, false);
        assert.equal(state.bindings.length, 0, 'configuration must precede any writer binding');
        state.events.push('configure');
        state.configurations.push(values);
        if (state.configureThrows) throw Error('CONFIGURE_FAILED');
        return state.accepted ? 1 : 0;
      };
    },
    log(line) { state.events.push('log'); state.logs.push(line); },
  });
  vm.runInContext(code, context);
  return { method, vectorType, state, addresses, gate, context, run: () => context.ensureFlightPosition() };
}

function rejected(label, mutate, configurations = 0) {
  const f = fixture(); mutate(f);
  assert.throws(f.run, undefined, label);
  assert.equal(f.state.configurations.length, configurations, `${label}: unexpected configuration attempt`);
  assert.equal(f.state.bindings.length, 0, `${label}: a rejected setup must not publish a writer`);
  assert.equal(f.context.positionBridgeReady, false, `${label}: a rejected setup must not become ready`);
  assert.equal(f.state.logs.length, 0, `${label}: a rejected setup must not announce readiness`);
  return f;
}

for (const [label, mutate] of [
  ['missing executor gate', f => { f.context.executorGate = null; }],
  ['executor bridge unavailable', f => { f.gate.positionBridgeAvailable = false; }],
  ['missing capture hook', f => { f.context.flightCaptureHook = null; }],
  ['capture bridge unavailable', f => { f.context.flightCaptureHook.positionBridgeAvailable = false; }],
  ['missing method', f => { f.state.method = null; }],
  ['static method', f => { f.method.isStatic = true; }],
  ['missing parameter', f => { f.method.params = 0; }],
  ['extra parameter', f => { f.method.params = 2; }],
  ['null return type', f => { f.method.retType.null = true; }],
  ['wrong return type', f => { f.method.retType.hash = '0xffff'; }],
  ['missing parameter array', f => { f.method.paramsNull = true; }],
  ['missing parameter metadata', f => { f.method.parameterNull = true; }],
  ['missing parameter type', f => { f.vectorType.null = true; }],
  ['wrong parameter type', f => { f.vectorType.hash = '0xffff'; }],
  ['missing vector size', f => { f.vectorType.size = 0; }],
  ['wrong vector size', f => { f.vectorType.size = 16; }],
  ['missing vector alignment', f => { f.vectorType.alignment = 0; }],
  ['wrong vector alignment', f => { f.vectorType.alignment = 8; }],
  ['missing position enum', f => { f.state.enumValue = null; }],
  ['wrong position enum', f => { f.state.enumValue = 2; }],
  ['missing configure export', f => { f.state.exportPresent = false; }],
]) rejected(label, mutate);

for (const [offset, hex] of helpers) {
  rejected(`mismatched fingerprint ${offset.toString(16)}`, f => { f.state.bytes.set(offset, '00'.repeat(hex.length / 2)); });
  rejected(`truncated fingerprint ${offset.toString(16)}`, f => { f.state.bytes.set(offset, hex.slice(0, -2)); });
  rejected(`unreadable helper ${offset.toString(16)}`, f => { f.state.unreadableOffset = offset; });
}
rejected('configure rejection', f => { f.state.accepted = false; }, 1);
rejected('configure exception', f => { f.state.configureThrows = true; }, 1);
rejected('binding exception', f => { f.state.bindThrows = true; }, 1);

{
  const f = fixture(); f.run();
  assert.equal(f.context.positionBridgeReady, true);
  assert.deepEqual(f.state.bindings, [f.method.fn]);
  assert.equal(f.state.configurations.length, 1);
  assert.deepEqual(f.state.configurations[0], [f.vectorType, 12, 4, ...f.addresses.values()]);
  assert.deepEqual(f.state.events, ['configure', 'bind', 'log']);
  assert.equal(f.state.reads.length, 6);
  assert.deepEqual(f.state.reads.find(read => read.offset === 0x4586a2c), { offset: 0x4586a2c, count: 4 },
    'the four-byte destroy function must not be fingerprinted as a 24-byte helper');
  const before = JSON.stringify({ lookups: f.state.lookups, reads: f.state.reads, exports: f.state.exports, events: f.state.events });
  f.run();
  assert.equal(JSON.stringify({ lookups: f.state.lookups, reads: f.state.reads, exports: f.state.exports, events: f.state.events }), before,
    'repeat setup reuses the published bridge without reads, configuration or rebinding');
}
{
  const f = rejected('retryable configuration rejection', f => { f.state.accepted = false; }, 1);
  f.state.accepted = true;
  f.run();
  assert.equal(f.context.positionBridgeReady, true);
  assert.equal(f.state.configurations.length, 2);
  assert.deepEqual(f.state.bindings, [f.method.fn], 'only a later successful attempt may publish the writer');
}
console.log('PASS position setup: gate/hook availability, exact script ABI and Vector3 layout, enum, six fingerprints, configure/bind failure isolation, single publication and reuse');
