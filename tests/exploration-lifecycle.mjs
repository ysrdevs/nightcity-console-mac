import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Execute the actual script control flow with engine boundaries mocked. This
// narrow adapter removes redscript local types/name literals and preserves
// unsigned integer division; combined scc compilation checks the real syntax.
const source = fs.readFileSync(new URL('../runtime/exploration/NCCCollisionFlightProbe.reds', import.meta.url), 'utf8');
function body(name) {
  const start = source.indexOf(`func ${name}(`);
  assert(start >= 0, name);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth > 0 && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(open + 1, end - 1)
    .replace(/\/\/[^\n]*/g, '')
    .replace(/let (\w+): [^;]+;/g, 'let $1;')
    .replace(/([\w.]+) \/ (\d+)u/g, 'Math.floor($1 / $2)')
    .replace(/\b(\d+)u\b/g, '$1')
    .replace(/\bn"/g, '"')
    .replace(/\bif\s+([^{}]+)\{/g, 'if ($1) {');
}
const signatures = {
  NCCFlightProbeEnsureMenuListener: '', NCCFlightProbeRequestStop: 'reason',
  NCCFlightProbeMenuChanged: 'value', NCCFlightProbeObserveInput: 'packet',
  NCCFlightProbeToggle: '', NCCFlightProbeRestore: 'scriptInterface, reason, returnToStart',
  NCCFlightProbeCaptureFilter: 'scriptInterface, value',
  NCCFlightProbeUpdate: 'timeDelta, stateContext, scriptInterface, stateName, machineName',
};

function fixture() {
  const state = { menu: false, registrationFails: false, restoreAccepted: true, teleports: 0,
    writes: 0, inputReads: 0, registrations: 0 };
  const probe = { active: false, requested: false, transitionPending: false, transitionSerial: 4,
    stopRequested: false, stopReason: '', restoreUnconfirmed: false,
    focusEpochValid: true, focusEpoch: 3, inputChecks: 0, captureWrites: 0,
    baselineFilter: { validFilter: true }, capturedFilter: { validFilter: true }, ownFilterWrite: false };
  const player = { nccCollisionFlightProbe: probe, GetGame: () => 'game', IsDead: () => false,
    NCCFlightProbeIsFilter: value => !!value?.validFilter, NCCFlightProbeIsVelocity: () => true,
    NCCFlightProbeZeroVelocity: () => ({}), NCCFlightInput() { state.inputReads++; return 3 * 65536 + 512; },
    NCCFlightProbeWriteFilter() { state.writes++; return state.restoreAccepted; } };
  const iface = { owner: player, IsMountedToObject: () => false, SetStateVectorParameter: () => true };
  probe.interfaceRef = iface;
  probe.capturedInterface = iface;
  const board = {
    GetBool: () => state.menu,
    RegisterListenerBool(id, owner, callback, fireExisting) {
      assert.equal(id, 'menu'); assert.equal(owner, player);
      assert.equal(callback, 'NCCFlightProbeMenuChanged'); assert.equal(fireExisting, true);
      state.registrations++;
      if (state.registrationFails) return null;
      player[callback](state.menu);
      return {};
    },
  };
  const context = vm.createContext({
    IsDefined: value => value !== null && value !== undefined,
    GetAllBlackboardDefs: () => ({ UI_System: { IsInMenu: 'menu' } }),
    GameInstance: { GetBlackboardSystem: () => ({ Get: () => board }),
      GetTeleportationFacility: () => ({ Teleport() { state.teleports++; } }) },
    physicsStateValue: { LinearVelocity: 'velocity' },
    VariantTypeName: () => 'filter',
  });
  for (const [name, args] of Object.entries(signatures)) {
    player[name] = vm.runInContext(`(function(${args}) {${body(name)}})`, context).bind(player);
  }
  return { state, probe, player, iface };
}
function ready(f) { assert.equal(f.player.NCCFlightProbeEnsureMenuListener(), true); }
function packet(epoch, flags = 512) { return epoch * 65536 + flags; }

{
  const f = fixture(); f.state.menu = true; ready(f);
  assert.equal(f.probe.stopRequested, false, 'an idle menu notification must not permanently latch cancellation');
  assert.match(f.player.NCCFlightProbeToggle(), /close the game menu/);
  f.state.menu = false; f.player.NCCFlightProbeMenuChanged(false);
  assert.match(f.player.NCCFlightProbeToggle(), /Requested/);
  assert.equal(f.probe.requested, true);
  assert.equal(f.state.registrations, 1, 'repeat commands reuse one listener');
}
for (const phase of ['active', 'requested', 'transitionPending']) {
  const f = fixture(); ready(f); f.probe[phase] = true;
  f.player.NCCFlightProbeMenuChanged(true);
  assert.equal(f.probe.stopRequested, true, phase);
  assert.equal(f.probe.requested, false);
  assert.equal(f.probe.transitionPending, false);
  assert.equal(f.probe.transitionSerial, 5, 'queued transition watchdog must become stale');
  f.player.NCCFlightProbeMenuChanged(false);
  assert.equal(f.probe.stopRequested, true, 'closing a menu cannot erase a pending stop');
  assert.equal(f.state.writes, 0); assert.equal(f.state.teleports, 0, 'notification must not touch physics');
}
{
  const f = fixture(); f.state.registrationFails = true;
  assert.match(f.player.NCCFlightProbeToggle(), /listener is unavailable/);
  assert.equal(f.probe.requested, false);
  assert.equal(f.probe.menuBlackboard, null);
}
{
  const f = fixture(); ready(f);
  f.player.NCCFlightProbeToggle();
  f.player.NCCFlightProbeObserveInput(packet(4)); // Focus lost/regained before first requested tick.
  assert.equal(f.probe.stopRequested, true);
  assert.equal(f.probe.requested, false);
  assert.equal(f.probe.focusEpoch, 4, 'compare the cached generation before accepting the observation');
  assert.match(f.probe.stopReason, /focus changed/);
  f.player.NCCFlightProbeRestore(f.iface, f.probe.stopReason, true);
  assert.equal(f.probe.stopRequested, false, 'inactive, confirmed cancellation completes without physics');
  assert.equal(f.state.writes, 0);
  f.player.NCCFlightProbeToggle();
  f.player.NCCFlightProbeObserveInput(packet(4, 512 + 256));
  assert.equal(f.probe.stopRequested, false, 'F1 block alone does not change the focus epoch');
  assert.equal(f.probe.requested, true, 'retry may wait for F1 to close');
}
for (const flags of [512 + 4096, 512 + 32768, 256]) {
  const f = fixture(); ready(f); f.probe.active = true; f.probe.requested = true;
  f.player.NCCFlightProbeObserveInput(packet(3, flags));
  assert.equal(f.probe.stopRequested, true, `unsafe packet flags ${flags}`);
  assert.equal(f.state.writes, 0, 'input observer only cancels intent');
  if (flags & 32768) assert.equal(f.probe.focusEpochValid, false);
}
{
  const f = fixture(); ready(f); f.probe.active = true; f.probe.requested = true;
  f.player.NCCFlightProbeMenuChanged(true); f.state.restoreAccepted = false;
  f.player.NCCFlightProbeRestore(f.iface, f.probe.stopReason, true);
  assert.equal(f.probe.active, true); assert.equal(f.probe.restoreUnconfirmed, true);
  assert.equal(f.probe.stopRequested, true, 'failed restoration retains cancellation');
  f.state.restoreAccepted = true;
  f.player.NCCFlightProbeRestore(f.iface, f.probe.stopReason, true);
  assert.equal(f.probe.active, false); assert.equal(f.probe.restoreUnconfirmed, false);
  assert.equal(f.probe.stopRequested, false);
  const before = { ...f.state };
  f.player.NCCFlightProbeUpdate(0.02, {}, f.iface, 'stand', 'Locomotion');
  assert.deepEqual(f.state, before, 'a completed stop must retain the idle fast path');
}
{
  const f = fixture(); ready(f); f.probe.restoreUnconfirmed = true; f.probe.stopRequested = true;
  assert.match(f.player.NCCFlightProbeToggle(), /restoration is unconfirmed/);
  f.probe.ownFilterWrite = true;
  f.player.NCCFlightProbeCaptureFilter(f.iface, { validFilter: true });
  assert.equal(f.probe.restoreUnconfirmed, true, 'owned ZERO must not clear uncertainty');
  f.probe.ownFilterWrite = false;
  f.player.NCCFlightProbeCaptureFilter({ owner: {} }, { validFilter: true });
  assert.equal(f.probe.restoreUnconfirmed, true, 'another owner cannot confirm cleanup');
  f.player.NCCFlightProbeCaptureFilter(f.iface, { validFilter: true });
  assert.equal(f.probe.restoreUnconfirmed, false, 'a verified original current-owner capture can confirm cleanup');
  f.player.NCCFlightProbeUpdate(0.02, {}, f.iface, 'stand', 'Locomotion');
  assert.equal(f.probe.stopRequested, false);
  assert.equal(f.state.inputReads, 0, 'uncertainty recovery does not introduce idle native polling');
}
console.log('PASS exploration lifecycle: actual script menu/focus cancellation, listener failure, restoration retry, idle completion, fresh-capture recovery and own-write exclusion');
