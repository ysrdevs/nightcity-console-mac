import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const transaction = source.split('// BEGIN CREATOR TRANSACTION')[1].split('// END CREATOR TRANSACTION')[0];
function harness(overrides = {}) {
  const files = new Map(), timers = [], queue = [];
  const state = { now: 1000, reloaded: false, gives: 0, count: 0, calls: 0, nameLoads: 0,
    baseLookups: [], typedLookups: [], ...overrides };
  const engine = {
    reload() { state.calls++; state.reloaded = true; },
    hasRecord(name) {
      if (name.startsWith('Items.Preset_')) { state.baseLookups.push(name); return !state.missingBase; }
      return state.existing || (state.reloaded && !state.importFails);
    },
    hasTypedRecord(method, name) {
      state.typedLookups.push([method, name]);
      return name !== state.missingRecord;
    },
    quantity() { return state.count; },
    give() { state.gives++; if (state.refuses) return false; if (!state.deferred) state.count++; return true; },
    inventoryEvidence() { return { queryItemID: 'query-seed-1', giveItemID: 'instance-seed-3', lastQuantity: state.count }; },
  };
  const context = vm.createContext({
    CREQ: 'request', CRES: 'response', pendingQ: queue, cmnMap: { 1: 'name', 2: 'flavor', 3: 'ability' },
    creatorContext() { if (state.unavailable) throw Error('TweakXL unavailable'); return engine; },
    cmnLoad() { state.nameLoads++; }, log() {}, Date: { now: () => state.now }, Process: { id: 42 },
    readFile: path => files.get(path), clearFile: path => files.delete(path),
    setTimeout: callback => timers.push(callback),
    File: function(path) { this.write = data => files.set(path, data); this.flush = () => {}; this.close = () => {}; },
  });
  vm.runInContext(transaction + ';globalThis.bridge={creatorPoll,creatorRun};', context);
  const req = (id = 'request-1', op = 'apply') => ({ id, pid: 42, op, deadline: 21000,
    ...(op === 'check' ? { baseRecord: 'Items.Preset_Lexington_Default', blueprint: 'Items.Iconic_Ranged_Weapon_Blueprint' }
      : { record: 'Items.CyberModManProbe', keys: [1, 2, 3] }) });
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
  assert.equal(h.state.nameLoads, 0);
  assert.equal(h.response().baseRecord, 'Items.Preset_Lexington_Default');
  assert.equal(h.response().blueprint, 'Items.Iconic_Ranged_Weapon_Blueprint');
  assert.deepEqual(h.state.baseLookups, ['Items.Preset_Lexington_Default']);
  assert.deepEqual(h.state.typedLookups, [
    ['GetItemBlueprintRecord', 'Items.Iconic_Ranged_Weapon_Blueprint'],
    ['GetAttachmentSlotRecord', 'AttachmentSlots.IconicWeaponModLegendary'],
    ['GetGameplayLogicPackageRecord', 'Items.IconicWeaponModAbilityBase'],
    ['GetItemRecord', 'Items.IconicWeaponModBase'],
  ]);
}
// Missing prerequisites must fail the read-only check: no reload, name refresh, inventory
// mutation or success acknowledgement. The UI waits for this before generating any files.
for (const [conditions, expected] of [
  [{ missingBase: true }, /selected base weapon is unavailable/],
  [{ missingRecord: 'Items.Iconic_Ranged_Weapon_Blueprint' }, /weapon blueprint is unavailable/],
  [{ missingRecord: 'AttachmentSlots.IconicWeaponModLegendary' }, /iconic attachment slot is unavailable/],
  [{ missingRecord: 'Items.IconicWeaponModAbilityBase' }, /iconic ability template is unavailable/],
  [{ missingRecord: 'Items.IconicWeaponModBase' }, /iconic mod template is unavailable/],
]) {
  const h = harness(conditions); h.poll(h.req('missing-prerequisite', 'check')); h.drain();
  assert.equal(h.response().ok, false); assert.match(h.response().message, expected);
  assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0); assert.equal(h.state.nameLoads, 0);
  assert.equal(h.timers.length, 0);
  if (conditions.missingBase) assert.deepEqual(h.state.typedLookups, []);
}
for (const [field, value] of [
  ['baseRecord', undefined], ['baseRecord', null], ['baseRecord', {}],
  ['baseRecord', ''], ['baseRecord', 'Items.Preset_Lexington_Default\n'],
  ['baseRecord', 'Items.Preset_X/../../Other'], ['baseRecord', 'Items.IconicWeaponModBase'],
  ['baseRecord', 'Items.Preset_' + 'A'.repeat(129)],
  ['blueprint', undefined], ['blueprint', null], ['blueprint', {}],
  ['blueprint', '__proto__'], ['blueprint', 'Items.Unrecognized_Blueprint'],
]) {
  const h = harness(), req = h.req('invalid-selection', 'check'); req[field] = value;
  h.poll(req); h.drain();
  assert.equal(h.response().ok, false); assert.match(h.response().message, /Invalid or missing Creator/);
  assert.deepEqual(h.state.baseLookups, []); assert.deepEqual(h.state.typedLookups, []);
  assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0); assert.equal(h.state.nameLoads, 0);
}
for (const [blueprint, slot] of [
  ['Items.Iconic_Ranged_Weapon_NoMuzzle_Blueprint', 'AttachmentSlots.IconicWeaponModLegendary'],
  ['Items.Iconic_Ranged_Weapon_NoScope_Blueprint', 'AttachmentSlots.IconicWeaponModLegendary'],
  ['Items.Iconic_Ranged_Weapon_NoAttachments_Blueprint', 'AttachmentSlots.IconicWeaponModLegendary'],
  ['Items.Iconic_Melee_Blueprint', 'AttachmentSlots.IconicMeleeWeaponMod1'],
]) {
  const h = harness(), req = h.req('blueprint-profile', 'check'); req.blueprint = blueprint;
  req.baseRecord = blueprint.includes('_Melee_') ? 'Items.Preset_Katana_Default' : 'Items.Preset_Nekomata_Default';
  h.poll(req); h.drain(); assert.equal(h.response().ok, true);
  assert.deepEqual(h.state.typedLookups[0], ['GetItemBlueprintRecord', blueprint]);
  assert.deepEqual(h.state.typedLookups[1], ['GetAttachmentSlotRecord', slot]);
  assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0);
}
// Exercise the actual runtime check with every selection the shipped UI can send.
// Read constants from the C++ table instead of maintaining a second test catalogue;
// unknown row syntax/macros fail here rather than silently skipping a profile.
{
  const overlay = fs.readFileSync(new URL('../overlay/overlay.mm', import.meta.url), 'utf8');
  const constants = new Map([...overlay.matchAll(/^#define\s+(CR_(?:BP|SLOT)_\w+)\s+"([^"]+)"/gm)]
    .map(match => [match[1], match[2]]));
  const table = overlay.split('static const CrBase kCrBases[] = {')[1]?.split('};')[0];
  assert(table, 'Creator base table must be present');
  const rows = [...table.matchAll(/^\s*\{"([^"]+)",\s*"([^"]+)",\s*(CR_BP_\w+),\s*(CR_SLOT_\w+),\s*(true|false)[^\n]*\},?\s*$/gm)];
  assert.equal(rows.length, [...table.matchAll(/\{/g)].length, 'Every Creator profile must be checked');
  assert(rows.length >= 7);
  for (const [index, row] of rows.entries()) {
    const blueprint = constants.get(row[3]), slot = constants.get(row[4]);
    assert(blueprint && slot, `Unknown profile macro for ${row[1]}`);
    const h = harness(), request = h.req(`catalogue-${index}`, 'check');
    request.baseRecord = row[2]; request.blueprint = blueprint;
    h.poll(request); h.drain();
    assert.equal(h.response().ok, true, `${row[1]}: ${h.response().message}`);
    assert.equal(h.response().baseRecord, row[2]); assert.equal(h.response().blueprint, blueprint);
    assert.deepEqual(h.state.typedLookups[1], ['GetAttachmentSlotRecord', slot]);
    assert.equal(h.state.calls, 0); assert.equal(h.state.gives, 0); assert.equal(h.state.nameLoads, 0);
  }
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
console.log('Creator selection preflight, transactions, timeouts, duplicate requests, import failures, and UTF-8 checks passed.');
