import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Execute the actual REDscript helper bodies with native overlap results mocked.
// This verifies control flow and value-copy semantics, NOT engine collision
// coverage, native query correctness, streaming readiness or gameplay safety.
// The separate headless compiler checks real REDscript types and syntax.
const source = fs.readFileSync(new URL('../runtime/exploration/NCCFlightClearance.reds', import.meta.url), 'utf8');
const limit = 2147483647;

class Vector4 {
  constructor(X = 0, Y = 0, Z = 0, W = 0) { Object.assign(this, { X, Y, Z, W }); }
  clone() { return new Vector4(this.X, this.Y, this.Z, this.W); }
  static subtract(a, b) { return new Vector4(a.X - b.X, a.Y - b.Y, a.Z - b.Z, a.W - b.W); }
  static LengthSquared(v) { return v.X * v.X + v.Y * v.Y + v.Z * v.Z + v.W * v.W; }
}
class EulerAngles { constructor() { Object.assign(this, { Roll: 0, Pitch: 0, Yaw: 0 }); } }
class TraceResult {
  constructor() { this.valid = false; }
  static IsValid(value) { return value.valid; }
}

const defaults = {
  Bool: () => false, Float: () => 0, Int32: () => 0, String: () => '',
  Vector4: () => new Vector4(), EulerAngles: () => new EulerAngles(), TraceResult: () => new TraceResult(),
};
const stateFields = [...source.match(/class NCCFlightClearanceState[^{]+\{([^}]+)\}/s)[1]
  .matchAll(/public let (\w+): (\w+);/g)];
class NCCFlightClearanceState {
  constructor() {
    for (const [, name, type] of stateFields) {
      assert(defaults[type], `unhandled REDscript state type ${type}`);
      this[name] = defaults[type]();
    }
  }
}

function body(name) {
  const start = source.indexOf(`func ${name}(`);
  assert(start >= 0, `missing actual helper ${name}`);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth > 0 && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0, name);
  return source.slice(open + 1, end - 1)
    .replace(/\/\/[^\n]*/g, '')
    .replace(/let (\w+): (\w+);/g, (_, local, type) => {
      assert(defaults[type], `unhandled REDscript local type ${type}`);
      return `let ${local} = defaults.${type}();`;
    })
    // REDscript structs copy by value, unlike JS object assignments.
    .replace(/\b(center|lowered) = (feet|observedFeet);/g, '$1 = $2.clone();')
    .replace(/(state\.(?:lastFeet|controlFeet)) = observedFeet;/g, '$1 = observedFeet.clone();')
    .replace('delta = observedFeet - state.controlFeet;', 'delta = Vector4.subtract(observedFeet, state.controlFeet);')
    .replace(/\bif\s+([^{}]+)\{/g, 'if ($1) {');
}
const signatures = {
  NCCFlightClearanceFinite: 'value', NCCFlightClearanceFinitePosition: 'value',
  NCCFlightClearanceReset: '', NCCFlightClearanceOverlap: 'scriptInterface, feet',
  NCCFlightClearanceInitialize: 'scriptInterface, observedFeet, capsuleHeight, capsuleRadius',
  NCCFlightClearanceVerifyControls: 'scriptInterface, observedFeet',
  NCCFlightClearanceAt: 'scriptInterface, observedFeet', NCCFlightClearanceReport: '',
};
const clear = Object.freeze({ hit: false, valid: false });
const occupied = Object.freeze({ hit: true, valid: true });

function fixture() {
  const native = { queued: [], calls: [], grounded: true };
  const player = {};
  const iface = {
    owner: player, IsOnGround: () => native.grounded,
    LocomotionOverlapTest(dimensions, position, rotation, out) {
      assert(native.queued.length, 'unexpected native query; provide an explicit mocked result');
      native.calls.push({ dimensions: dimensions.clone(), position: position.clone(), rotation: { ...rotation } });
      const result = native.queued.shift();
      out.valid = result.valid;
      return result.hit;
    },
  };
  const context = vm.createContext({ defaults, Vector4, TraceResult, NCCFlightClearanceState,
    IsDefined: value => value !== null && value !== undefined,
    AbsF: Math.abs, MaxF: Math.max, ToString: String,
    FloatToStringPrec: (value, digits) => value.toFixed(digits),
  });
  for (const [name, args] of Object.entries(signatures)) {
    player[name] = vm.runInContext(`(function(${args}) {${body(name)}})`, context).bind(player);
  }
  const feet = new Vector4(12, -5, 8, 1);
  const queue = (...results) => native.queued.push(...results);
  const init = (height = 1.8, radius = 0.4, position = feet, owner = iface) =>
    player.NCCFlightClearanceInitialize(owner, position, height, radius);
  const at = (position = feet, owner = iface) => player.NCCFlightClearanceAt(owner, position);
  const verify = (position = feet, owner = iface) => player.NCCFlightClearanceVerifyControls(owner, position);
  const initialize = () => { queue(clear, occupied); assert.equal(init(), true); };
  return { native, player, iface, feet, queue, init, at, verify, initialize,
    state: () => player.nccFlightClearance };
}
function noQueries(f, action, expected = false) {
  const before = f.native.calls.length;
  assert.equal(action(), expected);
  assert.equal(f.native.calls.length, before, 'rejected input must not reach the native query');
}

{
  const f = fixture();
  noQueries(f, () => f.at()); noQueries(f, () => f.verify());
  assert.match(f.player.NCCFlightClearanceReport(), /not initialized/);
  f.player.NCCFlightClearanceReset();
  assert.equal(f.state(), undefined, 'idle reset does not allocate state');
}
for (const owner of [null, undefined, { owner: {} }]) {
  const f = fixture(); noQueries(f, () => f.player.NCCFlightClearanceInitialize(owner, f.feet, 1.8, 0.4));
  assert.equal(f.state().ready, false); noQueries(f, () => f.at());
}
for (const [height, radius] of [[NaN, 0.4], [Infinity, 0.4], [-1, 0.4], [0.7, 0.4],
  [4.01, 0.4], [1.8, NaN], [1.8, Infinity], [1.8, -1], [1.8, 0.09], [3, 1.01]]) {
  const f = fixture(); noQueries(f, () => f.init(height, radius));
  assert.equal(f.state().ready, false); noQueries(f, () => f.at());
}
for (const component of ['X', 'Y', 'Z', 'W']) {
  for (const value of [NaN, Infinity, -Infinity, 1000001]) {
    const f = fixture(); const position = f.feet.clone(); position[component] = value;
    noQueries(f, () => f.init(1.8, 0.4, position));
    assert.equal(f.state().ready, false);
  }
}
{
  const f = fixture(); f.native.grounded = false;
  noQueries(f, () => f.init()); assert.equal(f.state().ready, false);
}
{
  const f = fixture(); const before = f.feet.clone();
  f.initialize(); const state = f.state();
  assert.equal(state.ready, true); assert.equal(state.clearControl, true);
  assert.equal(state.loweredControl, true); assert.equal(state.zeroControlsVerified, false);
  assert.equal(state.controlPasses, 1); assert.equal(state.queries, 2);
  assert.deepEqual(f.feet, before, 'actual REDscript value copies preserve the caller feet');
  const [standing, lowered] = f.native.calls;
  assert.deepEqual(standing.dimensions, new Vector4(0.4, 0.5, -1, 0));
  assert.deepEqual(standing.rotation, { Roll: 90, Pitch: 0, Yaw: 0 });
  assert.equal(standing.position.Z, 8.93);
  assert(Math.abs(lowered.position.Z - (8.93 - 0.43)) < 1e-12);
  f.native.grounded = false; // ZERO may clear contacts; repeat does not require that flag.
  f.queue(clear, occupied); assert.equal(f.verify(), true);
  assert.equal(state.zeroControlsVerified, true); assert.equal(state.controlPasses, 2);
  assert.equal(state.queries, 4);
  f.queue(clear); assert.equal(f.at(new Vector4(40, 60, 100, 1)), true, 'clear air is permitted');
  assert.equal(state.queries, 5); assert.equal(state.checks, 1);
  assert.match(f.player.NCCFlightClearanceReport(), /zeroControls=true.*controlPasses=2/);
}
for (const [height, radius, expectedHeight, expectedRadius] of [[1, 0.2, 1.8, 0.4], [2.6, 0.6, 2.6, 0.6]]) {
  const f = fixture(); f.queue(clear, occupied); assert.equal(f.init(height, radius), true);
  assert.equal(f.state().height, expectedHeight); assert.equal(f.state().radius, expectedRadius);
  assert.equal(f.native.calls[0].dimensions.Y, expectedHeight * 0.5 - expectedRadius);
}
for (const results of [[occupied], [clear, clear], [{ hit: true, valid: false }],
  [{ hit: false, valid: true }], [clear, { hit: true, valid: false }],
  [clear, { hit: false, valid: true }]]) {
  const f = fixture(); f.queue(...results); assert.equal(f.init(), false);
  assert.equal(f.state().ready, false); assert.equal(f.state().rejected, 1);
  noQueries(f, () => f.at()); noQueries(f, () => f.verify());
}
for (const results of [[occupied], [clear, clear], [{ hit: true, valid: false }],
  [{ hit: false, valid: true }], [clear, { hit: true, valid: false }]]) {
  const f = fixture(); f.initialize(); f.queue(...results);
  assert.equal(f.verify(), false); assert.equal(f.state().ready, false);
  assert.equal(f.state().zeroControlsVerified, false);
  noQueries(f, () => f.at()); noQueries(f, () => f.verify());
}
for (const failure of ['moved', 'owner', 'missing', 'nonfinite']) {
  const f = fixture(); f.initialize(); const position = f.feet.clone(); let owner = f.iface;
  if (failure === 'moved') position.X += 0.02;
  if (failure === 'owner') owner = { owner: {} };
  if (failure === 'missing') owner = null;
  if (failure === 'nonfinite') position.Z = NaN;
  noQueries(f, () => f.verify(position, owner));
  assert.equal(f.state().ready, false); noQueries(f, () => f.at());
}
{
  const f = fixture(); f.initialize();
  f.queue(occupied, { hit: true, valid: false }, { hit: false, valid: true });
  assert.equal(f.at(), false); assert.equal(f.at(), false); assert.equal(f.at(), false);
  assert.equal(f.state().blocked, 1); assert.equal(f.state().rejected, 2);
  assert.equal(f.state().ready, true, 'one occupied destination must not erase calibrated query readiness');
  f.queue(clear); assert.equal(f.at(), true, 'a later exit succeeds only after a fresh clear query');
  const badPosition = f.feet.clone(); badPosition.X = Infinity;
  noQueries(f, () => f.at(badPosition)); noQueries(f, () => f.at(f.feet, { owner: {} }));
  noQueries(f, () => f.at(f.feet, null));
  // A fresh owned locomotion interface is valid; another player's is not.
  f.queue(clear); assert.equal(f.at(f.feet, { ...f.iface }), true);
  f.player.NCCFlightClearanceReset(); noQueries(f, () => f.at());
  assert.equal(f.state().ready, false); assert.equal(f.state().zeroControlsVerified, false);
}
{
  const f = fixture(); f.initialize(); f.queue(clear, occupied); assert.equal(f.verify(), true);
  // A new failed initialization cannot reuse an older successful calibration.
  noQueries(f, () => f.init(NaN)); assert.equal(f.state().ready, false);
  assert.equal(f.state().zeroControlsVerified, false); noQueries(f, () => f.at());
}
{
  const f = fixture(); f.initialize(); const state = f.state();
  for (const name of ['queries', 'checks', 'blocked', 'rejected', 'controlPasses']) state[name] = limit;
  f.queue(occupied); assert.equal(f.at(), false);
  f.queue({ hit: true, valid: false }); assert.equal(f.at(), false);
  f.queue(clear, occupied); assert.equal(f.verify(), true);
  noQueries(f, () => f.at(f.feet, null));
  for (const name of ['queries', 'checks', 'blocked', 'rejected', 'controlPasses'])
    assert.equal(state[name], limit, `${name} must saturate without wrapping`);
}

console.log('PASS actual clearance helper: owner/finite/dimension guards, upright capsule value copies, grounded controls, post-ZERO controls, failure prevents later unchecked clearance, fresh destination query and saturating counters');
console.log('MOCK BOUNDARY: native overlap, TraceResult validity and grounded status are supplied fixtures; this is not proof of engine collision coverage or gameplay safety');
