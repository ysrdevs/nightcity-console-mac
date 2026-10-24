import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../runtime/red4ext_hooks.js', import.meta.url), 'utf8');
const fixture = JSON.parse(fs.readFileSync(new URL('./data/creator-rtti-2.5.json', import.meta.url)));
// The fixture is an exact, small projection of the real game's RTTI dump, not an invented
// static function model. Optionally check it against the complete retained SDK dump.
const dumpFlag = process.argv.indexOf('--rtti');
if (dumpFlag >= 0) {
  const bytes = fs.readFileSync(process.argv[dumpFlag + 1]), dump = JSON.parse(bytes);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), fixture.source_sha256);
  assert.equal(dump.uuid, fixture.uuid);
  for (const alias of fixture.absent_aliases) assert.equal(dump.classes[alias], undefined);
  for (const [name, cls] of Object.entries(fixture.classes)) {
    assert.equal(dump.classes[name].parent, cls.parent);
    const selected = new Set([...cls.funcs, ...cls.staticFuncs]);
    for (const table of ['funcs', 'staticFuncs'])
      assert.deepEqual(dump.classes[name][table].filter(method => selected.has(method)), cls[table]);
  }
}

const resolve = source.slice(source.indexOf('function resolveFunc(className'), source.indexOf('// ===== Observe('));
const resolveAny = source.slice(source.indexOf('function resolveAny('), source.indexOf('\n', source.indexOf('function resolveAny(')));
const contextCode = source.split('// BEGIN CREATOR CONTEXT')[1].split('// END CREATOR CONTEXT')[0];
const dispatch = source.slice(source.indexOf('function canDispatchCommand('), source.indexOf('function execute('));
const fnv = text => {
  let h = 0xcbf29ce484222325n;
  for (const c of text) h = BigInt.asUintN(64, (h ^ BigInt(c.charCodeAt(0))) * 0x100000001b3n);
  return h;
};

function harness(options = {}) {
  // Frida memory operations are replaced at the boundary. The actual resolver walks the
  // CClass arrays and parents, and the actual Creator preflight consumes its result.
  const cells = new Map(), types = new Map(), classes = new Map(), methods = new Map();
  const events = [], logs = [], inventory = [], itemIDs = new Map();
  const constructed = { fromTDBID: 0, query: 0 }; let next = 0x10000, nextSeed = 3;
  class Ptr {
    constructor(address = 0) { this.address = address; }
    add(offset) { return new Ptr(this.address + offset); }
    isNull() { return this.address === 0; }
    readPointer() { return new Ptr(cells.get(this.address) ?? 0); }
    writePointer(p) { cells.set(this.address, p.address); }
    readU32() { return cells.get(this.address) ?? 0; }
    writeU32(value) { cells.set(this.address, value); }
    readS32() { return this.readU32(); }
    readU8() { return this.readU32(); }
    writeU64(value) { cells.set(this.address, BigInt(value)); }
    readU64() { return { equals: other => BigInt(cells.get(this.address) ?? 0) === BigInt(other) }; }
    toString() { return '0x' + this.address.toString(16); }
  }
  const ptr = value => value instanceof Ptr ? value : new Ptr(Number(value));
  const alloc = (size = 0x100) => { const p = ptr(next); next += size + 0x10; return p; };
  const type = name => { const p = alloc(); types.set(p.address, '0x' + fnv(name).toString(16)); return p; };
  const tdbType = type('TweakDBID'), handleType = type('handle:gamedataWeaponItem_Record'), itemType = type('gameItemID');
  for (const [name, cls] of Object.entries(fixture.classes)) {
    const meta = alloc(0x80); classes.set(name, meta);
    for (const [table, offset] of [['funcs', 0x48], ['staticFuncs', 0x58]]) {
      const names = cls[table].filter(method => method !== options.missing);
      const array = alloc(names.length * 8); meta.add(offset).writePointer(array); meta.add(offset + 8).writeU32(names.length);
      names.forEach((method, i) => {
        const f = alloc(0x100), ret = alloc(), params = alloc(), param = alloc();
        methods.set(f.address, method); array.add(i * 8).writePointer(f);
        f.add(0x10).writeU64(fnv(method)); f.add(0x18).writePointer(ret);
        ret.writePointer(name === 'gameItemID' ? itemType : handleType);
        f.add(0x28).writePointer(params); params.writePointer(param); param.writePointer(tdbType);
        f.add(0x30).writeU32(options.badSignature ? 2 : 1);
      });
    }
  }
  const owner = alloc(), tx = alloc(), outerContext = alloc();
  const setItem = (address, name, seed) => { itemIDs.set(address.address, { name, seed }); return address; };
  const context = vm.createContext({
    fnv, u64: value => value, ptr, clsByName: name => classes.get(name) ?? null,
    T_TDB: '0x' + fnv('TweakDBID').toString(16),
    T_ITEM: '0x' + fnv('gameItemID').toString(16),
    cmnAttached: true, cmnReserve: {}, fromtd: options.noItemID ? null : {}, player: options.menu ? null : owner,
    nameOf: p => types.get(p.address), sigStr: () => 'signature', log: message => logs.push(message),
    hexp: p => JSON.stringify(itemIDs.get(p.address)),
    authPlayer: () => options.noPlayer ? null : owner,
    instOf: name => name === 'SingleplayerMenuGameController' ? (options.menuReady ? outerContext : null)
      : (options.noTransaction ? null : tx),
    tweakReloadMethod: () => () => events.push('reload'),
    Memory: { alloc }, tdbidBytes: name => name,
    // Exact 2.5 constructor semantics: unique instances get fresh seed >=3; queries use seed1.
    fromTDBID: (name, out) => { constructed.fromTDBID++; setItem(out, name, nextSeed++); },
    callFunc: (fn, receiver, ret, args) => {
      if (methods.get(fn.address) === 'CreateQuery') {
        constructed.query++; return setItem(alloc(), args[0], 1);
      }
      assert.match(methods.get(fn.address), /^Get(?:WeaponItem|Item)Record$/);
      // The native wrapper ignores x0, but its nonstatic executor route requires a live context.
      assert(receiver === owner || receiver === outerContext);
      events.push(['lookup', args[0]]);
      const result = alloc(); if (args[0] === 'Items.Preset_Lexington_Default') result.writePointer(alloc());
      return result;
    },
    callFuncRaw: (fn, receiver, ret, args) => {
      assert.equal(receiver, tx); assert.equal(args[0].inst, owner);
      const method = methods.get(fn.address), id = itemIDs.get(args[1].ptr.address);
      events.push([method, id.name, id.seed]);
      const result = alloc();
      if (method === 'GiveItem') { inventory.push({ ...id }); result.writeU32(1); }
      else if (method === 'GetItemQuantity') {
        // Inventory matcher0x1712b68: query seed1 matches by TDBID; otherwise the seed must match.
        result.writeU32(inventory.filter(item => item.name === id.name && (id.seed === 1 || item.seed === id.seed)).length);
      } else throw Error('Unexpected inventory method ' + method);
      return result;
    },
  });
  vm.runInContext(resolve + resolveAny + contextCode + dispatch + ';globalThis.test={resolveFunc,creatorContext,creatorProbe,canDispatchCommand};', context);
  return { ...context.test, events, logs, outerContext, constructed, inventory };
}

{
  const h = harness();
  // This is the real 2.5 registration that the old !record.isStatic gate rejected.
  const native = h.resolveFunc('gamedataTweakDBInterface', 'GetWeaponItemRecord');
  assert.equal(native.isStatic, false);
  assert.equal(h.resolveFunc('TweakDBInterface', 'GetWeaponItemRecord'), null);
  const creator = h.creatorContext();
  assert.equal(creator.hasRecord('Items.Preset_Lexington_Default'), true);
  assert.equal(creator.hasRecord('Items.CyberModManAbsent'), false);
  assert.equal(creator.quantity('Items.Preset_Lexington_Default'), 0);
  assert.equal(creator.give('Items.Preset_Lexington_Default'), true);
  assert.equal(creator.quantity('Items.Preset_Lexington_Default'), 1);
  assert.equal(creator.quantity('Items.Preset_Lexington_Default'), 1);
  assert.deepEqual(h.constructed, { fromTDBID: 1, query: 1 });
  assert.equal(h.inventory[0].seed, 3);
  assert.equal(JSON.parse(creator.inventoryEvidence('Items.Preset_Lexington_Default').queryItemID).seed, 1);
}
{
  const h = harness({ missing: 'GetWeaponItemRecord' });
  assert.equal(h.creatorContext().hasRecord('Items.Preset_Lexington_Default'), true);
}
for (const [conditions, expected] of [
  [{ missing: 'GetItemQuantity' }, /gameTransactionSystem\.GetItemQuantity/],
  [{ missing: 'GiveItem' }, /gameTransactionSystem\.GiveItem/],
  [{ missing: 'CreateQuery' }, /gameItemID\.CreateQuery/],
  [{ noPlayer: true }, /local player/], [{ noTransaction: true }, /gameTransactionSystem/],
  [{ noItemID: true }, /ItemID\.FromTDBID/], [{ badSignature: true }, /unsupported signature/],
]) {
  const h = harness(conditions);
  assert.throws(() => h.creatorContext(), expected);
  assert.deepEqual(h.events, []);
}
{
  const h = harness({ menu: true, noPlayer: true, noTransaction: true, noItemID: true });
  h.creatorProbe(h.outerContext);
  assert.deepEqual(h.events, [['lookup', 'Items.Preset_Lexington_Default']]);
  assert(h.logs.some(line => line.endsWith('Items.Preset_Lexington_Default: FOUND')));
  assert(source.indexOf("if(t[0]==='creatorprobe')") < source.indexOf("if(!player){ log('NOT IN GAME yet:"));
}
{
  const h = harness({ menu: true });
  assert.throws(() => h.creatorProbe(null), /current script context/);
  assert.deepEqual(h.events, []); // Refuse before reaching the native executor's null-context fallback.
}
{
  const h = harness({ menu: true, menuReady: true });
  assert.equal(h.canDispatchCommand('creatorprobe', 0, null), false); // Keep queued across global calls.
  assert.equal(h.canDispatchCommand('creatorprobe', 2, h.outerContext), true); // Use the current nested menu call.
  assert.equal(h.canDispatchCommand('give Items.money', 2, h.outerContext), false);
  assert.equal(h.canDispatchCommand({ creator: {} }, 2, h.outerContext), false);
  assert.equal(h.canDispatchCommand({ creator: {} }, 0, null), true); // Creator resolves its own owner.
  const early = harness({ menu: true });
  assert.equal(early.canDispatchCommand('creatorprobe', 0, early.outerContext), false); // Before main menu/TDB.
}
console.log('Real 2.5 RTTI table resolution, Creator preflight and read-only menu probe passed.');
