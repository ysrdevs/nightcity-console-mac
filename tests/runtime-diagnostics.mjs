import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const diagnostics = source.split('// BEGIN RUNTIME DIAGNOSTICS')[1].split('// END RUNTIME DIAGNOSTICS')[0];
const destination = '/tmp/cp2077_runtime_diagnostics.json';
const fields = ['schema_version', 'process_id', 'script_loaded_at_unix', 'updated_at_unix',
  'executor_filter', 'localization_filter', 'game_support'].sort();

function harness(initialFault = null) {
  const files = new Map(), descriptors = new Map(), published = [], removed = [];
  const state = { now: 1234000, fault: initialFault, sequence: 0, creates: 0 };
  const native = {
    mkstemp(path) {
      state.creates++;
      if (state.fault === 'create') return -1;
      const fd = ++state.sequence;
      path.value = path.value.replace('XXXXXX', String(fd).padStart(6, '0'));
      assert(!files.has(path.value), 'temporary files must be created exclusively');
      files.set(path.value, ''); descriptors.set(fd, path.value);
      return fd;
    },
    write(fd, bytes, count) {
      assert.equal(count, Buffer.byteLength(bytes.value), 'sidecar is bounded ASCII JSON');
      if (state.fault === 'write') throw Error('PRIVATE_WRITE_ERROR');
      if (state.fault === 'short_write') {
        files.set(descriptors.get(fd), bytes.value.slice(0, 5));
        return 5;
      }
      files.set(descriptors.get(fd), bytes.value);
      return { toString: () => String(count) }; // Frida may represent a native long as Int64.
    },
    close(fd) {
      assert(descriptors.has(fd)); descriptors.delete(fd);
      return state.fault === 'close' ? -1 : 0;
    },
    rename(from, to) {
      if (state.fault === 'rename') return -1;
      assert.equal(to.value, destination);
      const bytes = files.get(from.value);
      assert(Buffer.byteLength(bytes) <= 1024);
      const object = JSON.parse(bytes);
      assert.deepEqual(Object.keys(object).sort(), fields);
      files.set(to.value, bytes); files.delete(from.value); published.push(object);
      return 0;
    },
    unlink(path) { removed.push(path.value); files.delete(path.value); return 0; },
  };
  const context = vm.createContext({
    Process: { id: 42 }, Date: { now: () => state.now },
    Memory: { allocUtf8String: value => ({ value }) },
    Module: { findGlobalExportByName: name => state.fault === 'resolve' ? null : name },
    NativeFunction: function(address) { return typeof address === 'string' ? native[address] : () => {}; },
  });
  vm.runInContext(diagnostics, context);
  return { context, state, files, published, removed, descriptors,
    update: values => context.nccRuntimeDiagnostics(values),
    latest: () => JSON.parse(files.get(destination)) };
}

{
  const h = harness();
  assert.deepEqual(h.latest(), { schema_version: 1, process_id: 42,
    script_loaded_at_unix: 1234, updated_at_unix: 1234,
    executor_filter: 'initializing', localization_filter: 'initializing', game_support: 'unknown' });
  h.state.now = 1235000;
  h.update({ executor_filter: 'native', game_support: 'supported', command: 'PRIVATE_COMMAND',
    process_id: 999, script_loaded_at_unix: 0, localization_filter: 'PRIVATE_NAME' });
  assert.equal(h.latest().executor_filter, 'native');
  assert.equal(h.latest().localization_filter, 'initializing');
  assert.equal(h.latest().updated_at_unix, 1235);
  assert.equal(h.latest().script_loaded_at_unix, 1234);
  assert.equal(h.latest().process_id, 42);
  assert(!h.files.get(destination).includes('PRIVATE'));
  const writes = h.published.length;
  h.state.now = 1236000;
  h.update({ executor_filter: 'native', unknown: 'ignored' });
  h.update(Object.create({ localization_filter: 'compatibility' }));
  assert.equal(h.published.length, writes, 'unchanged, unknown and inherited fields do not write');
  h.update({ localization_filter: 'compatibility' });
  h.update({ localization_filter: 'unavailable' });
  assert.equal(h.latest().localization_filter, 'unavailable');
  assert.equal(h.files.size, 1); assert.equal(h.descriptors.size, 0);
}

// Failure at every I/O boundary must preserve the previous complete file and never escape.
// A subsequent independent transition can still publish the current in-memory state.
for (const fault of ['create', 'write', 'short_write', 'close', 'rename']) {
  const h = harness(), before = h.files.get(destination);
  h.state.fault = fault;
  assert.doesNotThrow(() => h.update({ executor_filter: 'native' }));
  assert.equal(h.files.get(destination), before, `${fault} must not publish partial JSON`);
  assert.equal(h.descriptors.size, 0, `${fault} must close created descriptors`);
  assert.equal(h.files.size, 1, `${fault} must clean up owned temporary files`);
  assert(!h.removed.some(path => path.endsWith('XXXXXX')), 'never unlink an uncreated temporary path');
  h.state.fault = null;
  h.update({ localization_filter: 'native' });
  assert.equal(h.latest().executor_filter, 'native');
  assert.equal(h.latest().localization_filter, 'native');
}
{
  const h = harness('resolve');
  assert.equal(h.files.size, 0);
  h.state.fault = null;
  h.update({ game_support: 'supported' });
  assert.equal(h.latest().script_loaded_at_unix, 1234);
}
console.log('PASS runtime snapshot schema/privacy, stable session identity, transition-only writes, atomic replacement and I/O failure isolation');

// Exercise production detection and installation blocks, rather than merely testing setter inputs.
const detection = source.slice(source.indexOf('function getGameVersion()'), source.indexOf('function gameOffsets()'));
for (const supported of [true, false]) {
  const h = harness();
  Object.assign(h.context, {
    GAME_OFFSETS: { '2.5': { rttiGet: 4 } }, GAME_FINGERPRINTS: { '2.5': '01020304' },
    getModuleBase: () => ({ add: () => ({ readByteArray: () => new Uint8Array(supported ? [1, 2, 3, 4] : [9]) }) }),
    logInfo() {}, logError() {},
  });
  vm.runInContext('let gameVersion;' + detection + ';getGameVersion();', h.context);
  assert.equal(h.latest().game_support, supported ? 'supported' : 'unsupported');
  if (!supported) {
    assert.equal(h.latest().executor_filter, 'unavailable');
    assert.equal(h.latest().localization_filter, 'unavailable');
  }
}

const executor = source.slice(source.indexOf('// BEGIN EXECUTOR LISTENER'),
  source.indexOf('// ---- AUTO-LOAD:', source.indexOf('// BEGIN EXECUTOR LISTENER')));
for (const mode of ['native', 'legacy231', 'native_failure']) {
  const h = harness();
  const attaches = [];
  Object.assign(h.context, {
    isGame231: () => mode === 'legacy231',
    createExecutorGate() {
      if (mode === 'native_failure') throw Error('PRIVATE_NATIVE_ERROR');
      return { callbacks: { native: true }, pending() {}, observers() {} };
    },
    Interceptor: { attach(address, callbacks) { attaches.push(callbacks); } },
    execAddr: 'executor', pendingQ: [], obsCount: 0, depthByTid: {},
    captureExecutorContext() {}, drainExecutorCommand() {}, log() {},
  });
  vm.runInContext('let executorGate = null;' + executor, h.context);
  assert.equal(h.latest().executor_filter, mode === 'native' ? 'native' : 'compatibility');
  assert.equal(attaches.length, 1);
  assert(!h.files.get(destination).includes('PRIVATE'));
}

const localization = source.slice(source.indexOf('function cmnInstall()'),
  source.indexOf("try { cmnLog('=== cybermodman custom-names init ===')"));
for (const mode of ['native', 'legacy231', 'native_failure', 'all_attach_failure', 'fingerprint_failure', 'unsupported', 'missing_module']) {
  const h = harness();
  const fingerprints = { 1: 'ffc301d1f85f03a9f65704a9f44f05a9fd7b06a9fd830191f40303aaf50302aaf70301aaf60300aaf30308aa',
    2: 'ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f40301aaf30300aa3f50007183010054e00313aa088c41f8' };
  const base = { add: offset => ({ readByteArray: () => mode === 'fingerprint_failure'
    ? new Uint8Array([0]) : new Uint8Array(Buffer.from(fingerprints[offset], 'hex')) }) };
  Object.assign(h.context, {
    cmnAttached: false, cmnNativeGate: null, cmnMap: {}, cmnLog() {},
    gameOffsets: () => mode === 'unsupported' ? null : { locLookup: 1, poolCString: 2 },
    getModuleBase: () => mode === 'missing_module' ? null : base, getGameVersion: () => '2.5',
    isGame231: () => mode === 'legacy231',
    createLocalizationGate() {
      if (mode === 'native_failure') throw Error('PRIVATE_LOCALIZATION_ERROR');
      return { callbacks: {} };
    },
    Interceptor: { attach() { if (mode === 'all_attach_failure') throw Error('PRIVATE_ATTACH_ERROR'); } },
  });
  vm.runInContext(localization + ';cmnInstall();', h.context);
  const expected = ['all_attach_failure', 'fingerprint_failure', 'unsupported', 'missing_module'].includes(mode)
    ? 'unavailable' : mode === 'native' ? 'native' : 'compatibility';
  assert.equal(h.latest().localization_filter, expected, mode);
  assert(!h.files.get(destination).includes('PRIVATE'));
}
console.log('PASS production supported/unsupported detection, executor native/legacy/fallback, localization native/fallback/unavailable states');
