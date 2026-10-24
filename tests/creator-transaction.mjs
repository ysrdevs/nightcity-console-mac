import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const transaction = source.split('// BEGIN CREATOR TRANSACTION')[1].split('// END CREATOR TRANSACTION')[0];
function harness(overrides = {}) {
  const files = new Map(), timers = [], queue = [];
  const state = { now: 1000, reloaded: false, gives: 0, count: 0, calls: 0, ...overrides };
  const engine = {
    reload() { state.calls++; state.reloaded = true; },
    hasRecord() { return state.existing || (state.reloaded && !state.importFails); },
    quantity() { return state.count; },
    give() { state.gives++; if (state.refuses) return false; if (!state.deferred) state.count++; return true; },
    inventoryEvidence() { return { queryItemID: 'query-seed-1', giveItemID: 'instance-seed-3', lastQuantity: state.count }; },
  };
  const context = vm.createContext({
    CREQ: 'request', CRES: 'response', pendingQ: queue, cmnMap: { 1: 'name', 2: 'flavor', 3: 'ability' },
    creatorContext() { if (state.unavailable) throw Error('TweakXL unavailable'); return engine; },
    cmnLoad() {}, log() {}, Date: { now: () => state.now }, Process: { id: 42 },
    readFile: path => files.get(path), clearFile: path => files.delete(path),
    setTimeout: callback => timers.push(callback),
    File: function(path) { this.write = data => files.set(path, data); this.flush = () => {}; this.close = () => {}; },
  });
  vm.runInContext(transaction + ';globalThis.bridge={creatorPoll,creatorRun};', context);
  const req = (id = 'request-1', op = 'apply') => ({ id, pid: 42, op, deadline: 21000, record: 'Items.CyberModManProbe', keys: [1, 2, 3] });
  const poll = request => { files.set('request', JSON.stringify(request)); context.bridge.creatorPoll(); };
  const drain = () => { while (queue.length) { const x = queue.shift(); context.bridge.creatorRun(x.creator, x.state); } };
  const response = () => files.has('response') ? JSON.parse(files.get('response')) : null;
  return { state, files, timers, req, poll, drain, response, context };
}

// A returned Reload() call does not establish import success; neither a rejected record nor an
// existing record may cause an inventory mutation or a false successful acknowledgement.
for (const conditions of [{ importFails: true }, { existing: true }, { unavailable: true }]) {
  const h = harness(conditions); h.poll(h.req()); h.drain();
  assert.equal(h.response().ok, false); assert.equal(h.state.gives, 0);
}
{
  const h = harness(); h.poll(h.req('preflight', 'check')); h.drain();
  assert.equal(h.response().ok, true); assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0);
}
{
  const h = harness({ deferred: true }); h.poll(h.req()); h.drain();
  assert.equal(h.response(), null); assert.equal(h.state.gives, 1);
  h.state.count = 1; h.timers.shift()(); h.drain();
  assert.equal(h.response().ok, true); assert.equal(h.response().after, 1); assert.equal(h.state.gives, 1);
  assert.equal(h.response().before, 0); assert.equal(h.response().queryItemID, 'query-seed-1');
  // Retransmission is acknowledged without giving a second item, even after another request.
  h.poll(h.req('next-check', 'check')); h.drain(); h.poll(h.req()); h.drain();
  assert.equal(h.response().id, 'request-1'); assert.equal(h.response().ok, true); assert.equal(h.state.gives, 1);
}
{
  const h = harness({ refuses: true }); h.poll(h.req()); h.drain();
  assert.equal(h.response().ok, false); assert.equal(h.state.gives, 1);
}
{
  const h = harness(); h.poll(h.req()); h.state.now = 22000; h.context.bridge.creatorPoll();
  assert.equal(h.response().ok, false); h.drain(); assert.equal(h.state.gives, 0);
  // A stalled executor cannot leave Creator permanently busy after the UI times out.
  h.state.now = 1000; h.poll(h.req('later', 'check')); h.drain(); assert.equal(h.response().ok, true);
}
{
  const h = harness({ deferred: true }); h.poll(h.req()); h.drain();
  h.state.now = 22000; h.context.bridge.creatorPoll();
  assert.equal(h.response().ok, false); assert.match(h.response().message, /Check inventory/);
  assert.equal(h.response().before, 0); assert.equal(h.response().after, 0);
  assert.equal(h.response().giveItemID, 'instance-seed-3');
  h.state.count = 1; h.timers.shift()(); h.drain(); assert.equal(h.response().ok, false); assert.equal(h.state.gives, 1);
}
{
  const h = harness(); const r = h.req(); r.keys = [1, 2, 4]; h.poll(r); h.drain();
  assert.equal(h.response().ok, false); assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0);
}
{
  const h = harness(); const r = h.req(); r.pid = 41; h.poll(r); h.drain();
  assert.equal(h.response().ok, false); assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0);
}

const utf8 = source.slice(source.indexOf('function cmnUtf8Length'), source.indexOf('// CString\'s length'));
const lengths = vm.createContext({}); vm.runInContext(utf8 + ';globalThis.lengthOf=cmnUtf8Length;', lengths);
for (const s of ['Short', 'A'.repeat(19), 'A'.repeat(20), 'Étoile — 東京', '🔥'.repeat(12)])
  assert.equal(lengths.lengthOf(s), Buffer.byteLength(s, 'utf8'));

// Optional read-only check against the locally retained, legally owned game binary fixtures.
const fixtureFlag = process.argv.indexOf('--fixtures');
if (fixtureFlag >= 0) {
  const root = process.argv[fixtureFlag + 1];
  const expected = [
    'ffc301d1f85f03a9f65704a9f44f05a9fd7b06a9fd830191f40303aaf50302aaf70301aaf60300aaf30308aa',
    'ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f40301aaf30300aa3f50007183010054e00313aa088c41f8',
  ];
  for (const [version, offsets] of [['2.3.1', [0x2f6ea14, 0x2c904]], ['2.5.0', [0x1c331f4, 0x2c7e4]]]) {
    const fd = fs.openSync(`${root}/${version}/Cyberpunk2077`, 'r');
    for (let i = 0; i < offsets.length; ++i) {
      const bytes = Buffer.alloc(expected[i].length / 2); fs.readSync(fd, bytes, 0, bytes.length, offsets[i]);
      assert.equal(bytes.toString('hex'), expected[i], `${version} ${offsets[i].toString(16)}`);
    }
    fs.closeSync(fd);
  }
}
console.log('Creator transactions, timeouts, duplicate requests, import failures, and UTF-8 checks passed.');
