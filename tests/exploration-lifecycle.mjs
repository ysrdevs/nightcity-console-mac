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
    .replace(/\s+as PlayerPuppet/g, '')
    .replace(/\bif\s+([^{}]+)\{/g, 'if ($1) {');
}
const signatures = {
  NCCFlightProbeEnsureMenuListener: '', NCCFlightProbeRequestStop: 'reason',
  NCCFlightProbeMenuChanged: 'value', NCCFlightProbeObserveInput: 'packet',
  NCCFlightProbeToggle: '', NCCFlightProbePrepare: 'commandPacket', NCCFlightProbeReturn: '',
  NCCFlightProbeRestore: 'scriptInterface, reason, returnToStart',
  NCCFlightProbeCaptureFilter: 'scriptInterface, value',
  NCCFlightProbePreparationTick: 'timeDelta, stateContext, scriptInterface, stateName, machineName',
  NCCFlightProbePreparationComplete: 'stateContext, scriptInterface, stateName, machineName',
  NCCFlightProbeUpdate: 'timeDelta, stateContext, scriptInterface, stateName, machineName',
};

function fixture() {
  const state = { menu: false, registrationFails: false, restoreAccepted: true, teleports: 0,
    writes: 0, inputReads: 0, registrations: 0, packet: 3 * 65536 + 512,
    normalWrites: 0, updates: 0, originalUpdates: 0, current: true, grounded: true, zeroPreset: false };
  const probe = { active: false, requested: false, transitionPending: false, transitionSerial: 4,
    stopRequested: false, stopReason: '', restoreUnconfirmed: false,
    focusEpochValid: true, focusEpoch: 3, inputChecks: 0, captureWrites: 0,
    baselineFilter: { validFilter: true }, capturedFilter: { validFilter: true }, ownFilterWrite: false,
    preparePending: false, prepared: false, prepareCallbacks: 0, prepareElapsed: 0 };
  const player = { nccCollisionFlightProbe: probe, GetGame: () => 'game', IsDead: () => false,
    NCCFlightProbeIsFilter: value => !!value?.validFilter, NCCFlightProbeIsVelocity: () => true,
    NCCFlightProbeZeroVelocity: () => ({}), NCCFlightInput() { state.inputReads++; return state.packet; },
    NCCFlightCameraBefore: () => false,
    NCCFlightProbeWriteFilter() { state.writes++; return state.restoreAccepted; } };
  const iface = { owner: player, IsMountedToObject: () => false, SetStateVectorParameter: () => true,
    IsPlayerInBraindance: () => false, IsSceneAnimationActive: () => false, IsOnGround: () => state.grounded };
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
    Equals: (a, b) => a === b, NotEquals: (a, b) => a !== b,
    NCCCollisionFlightProbeState: class {
      constructor() { Object.assign(this, { ...probe, focusEpochValid: false, capturedFilter: undefined,
        capturedInterface: undefined, interfaceRef: undefined, menuBlackboard: undefined, menuListener: undefined }); }
    },
    wrappedMethod: () => { state.originalUpdates++; if (state.afterOriginalUpdate) state.afterOriginalUpdate(); },
  });
  for (const [name, args] of Object.entries(signatures)) {
    player[name] = vm.runInContext(`(function(${args}) {${body(name)}})`, context).bind(player);
  }
  const stateContext = { IsStateActive: (machine, name) => state.current && machine === 'Locomotion' && name === 'stand' };
  const transition = { GetStateName: () => 'stand', GetStateMachineName: () => 'Locomotion',
    GetStaticBoolParameterDefault: () => { state.staticReads = (state.staticReads || 0) + 1; return state.zeroPreset; },
    SetCollisionFilter(value) {
      assert.equal(value, iface); state.normalWrites++;
      if (!state.captureFails) player.NCCFlightProbeCaptureFilter(value, { validFilter: true });
      if (state.afterCapture) state.afterCapture();
    } };
  const update = vm.runInContext(`(function(timeDelta, stateContext, scriptInterface) {${body('OnUpdate')}})`, context).bind(transition);
  return { state, probe, player, iface, stateContext, update };
}
function ready(f) { assert.equal(f.player.NCCFlightProbeEnsureMenuListener(), true); }
function packet(epoch, flags = 512) { return epoch * 65536 + flags; }
function start(f, value = packet(3)) { return f.player.NCCFlightProbePrepare(value); }

{
  const f = fixture(); f.state.menu = true; ready(f);
  assert.equal(f.probe.stopRequested, false, 'an idle menu notification must not permanently latch cancellation');
  assert.match(start(f), /close the game menu/);
  f.state.menu = false; f.player.NCCFlightProbeMenuChanged(false);
  assert.match(start(f), /Requested/);
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
  assert.match(start(f), /listener is unavailable/);
  assert.equal(f.probe.requested, false);
  assert.equal(f.probe.menuBlackboard, null);
}
{
  const f = fixture(); ready(f);
  start(f);
  f.player.NCCFlightProbeObserveInput(packet(4)); // Focus lost/regained before first requested tick.
  assert.equal(f.probe.stopRequested, true);
  assert.equal(f.probe.requested, false);
  assert.equal(f.probe.focusEpoch, 4, 'compare the cached generation before accepting the observation');
  assert.match(f.probe.stopReason, /focus changed/);
  f.player.NCCFlightProbeRestore(f.iface, f.probe.stopReason, true);
  assert.equal(f.probe.stopRequested, false, 'inactive, confirmed cancellation completes without physics');
  assert.equal(f.state.writes, 0);
  start(f, packet(4));
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
  assert.match(start(f), /restoration is unconfirmed/);
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
{
  const f = fixture(); f.player.nccCollisionFlightProbe = null;
  assert.match(start(f, packet(7, 512 + 256)), /Requested/);
  const created = f.player.nccCollisionFlightProbe;
  assert.equal(created.focusEpoch, 7); assert.equal(created.preparePending, true);
  assert.equal(f.state.inputReads, 0, 'command packet is a cancellation seed, never a scripted input call');
  assert.equal(f.state.normalWrites, 0);
  f.state.packet = packet(7, 512 + 256);
  f.player.NCCFlightProbeUpdate = () => { f.state.updates++; };
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.state.normalWrites, 0, 'F1 waits without physics');
  assert.equal(created.prepareElapsed, 0, 'F1 does not consume the simulation readiness budget');
  f.state.packet = packet(7);
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.state.normalWrites, 1); assert.equal(created.prepared, true);
  assert.equal(f.state.updates, 0, 'capture callback cannot also enter flight movement');
  assert.equal(f.state.writes, 0); assert.equal(f.state.teleports, 0);
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.state.normalWrites, 1, 'only one original setter attempt per click');
  assert.equal(f.state.updates, 1, 'next owned callback dispatches the existing activation logic');
}
{
  const f = fixture(); f.state.packet = packet(9);
  start(f, packet(9));
  assert.equal(f.probe.focusEpoch, 9, 'a new explicit start after idle focus change works once');
  f.player.NCCFlightProbeUpdate = () => { f.state.updates++; };
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.probe.prepared, true); assert.equal(f.probe.stopRequested, false);
}
for (const phase of ['active', 'requested', 'transitionPending']) {
  const f = fixture(); f.probe[phase] = true;
  assert.match(start(f, packet(9)), /return and restore/);
  assert.equal(f.probe.focusEpoch, 3, 'stop request must never reseed the active generation');
  assert.equal(f.probe.preparePending, false);
}
for (const flags of [256, 512 + 4096, 512 + 32768]) {
  const f = fixture(); assert.match(start(f, packet(3, flags)), /unavailable, unfocused, or exhausted/);
  assert.equal(f.probe.requested, false); assert.equal(f.state.normalWrites, 0);
}
for (const value of [packet(4), packet(3, 256), packet(3, 512 + 4096), packet(3, 512 + 32768)]) {
  const f = fixture(); start(f); f.state.packet = value;
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.probe.requested, false, 'actual PSM input must independently accept command-time generation');
  assert.equal(f.state.normalWrites, 0); assert.equal(f.state.writes, 0);
}
for (const failure of ['zeroPreset', 'captureFails', 'staleBefore', 'staleAfter', 'ownerAfter', 'menuAfter']) {
  const f = fixture(); start(f);
  if (failure === 'zeroPreset' || failure === 'captureFails') f.state[failure] = true;
  if (failure === 'staleBefore') f.state.afterOriginalUpdate = () => { f.state.current = false; };
  if (failure === 'staleAfter') f.state.afterCapture = () => { f.state.current = false; };
  if (failure === 'ownerAfter') f.state.afterCapture = () => { f.iface.owner = {}; };
  if (failure === 'menuAfter') f.state.afterCapture = () => f.player.NCCFlightProbeMenuChanged(true);
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.probe.prepared, false, failure);
  assert.equal(f.probe.requested, false, failure);
  assert.equal(f.state.writes, 0); assert.equal(f.state.teleports, 0);
  if (failure === 'ownerAfter') f.iface.owner = f.player;
  f.state.afterOriginalUpdate = null; f.state.afterCapture = null;
  const writes = f.state.normalWrites;
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.state.normalWrites, writes, 'failed preparation cannot automatically retry');
}
for (const change of ['state', 'interface']) {
  const f = fixture(); start(f); f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.probe.prepared, true);
  if (change === 'state') f.state.current = false;
  const iface = change === 'interface' ? { ...f.iface } : f.iface;
  f.update(0.02, f.stateContext, iface);
  assert.equal(f.probe.requested, false); assert.equal(f.probe.prepared, false);
  assert.match(f.probe.status, /prepared locomotion state changed/);
  assert.equal(f.state.normalWrites, 1); assert.equal(f.state.writes, 0);
}
for (const change of ['focusAfterCapture', 'menuCallbackAfterCapture', 'menuPollAfterCapture']) {
  const f = fixture(); start(f); f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.probe.prepared, true); assert.equal(f.probe.active, false);
  if (change === 'focusAfterCapture') f.state.packet = packet(4);
  else {
    f.state.menu = true;
    if (change === 'menuCallbackAfterCapture') f.player.NCCFlightProbeMenuChanged(true);
  }
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.probe.requested, false); assert.equal(f.probe.active, false);
  assert.equal(f.state.normalWrites, 1, 'deferred activation cancellation cannot refresh again');
  assert.equal(f.state.writes, 0, 'no ZERO or collision restore is needed before activation');
  assert.equal(f.state.teleports, 0);
  f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.state.normalWrites, 1); assert.equal(f.state.writes, 0, 'no automatic retry');
}
{
  const f = fixture(); start(f); f.state.grounded = false;
  for (let i = 0; i < 10; i++) f.update(0.5, f.stateContext, f.iface);
  assert.equal(f.probe.requested, false); assert.match(f.probe.status, /5-second/);
  assert.equal(f.state.normalWrites, 0);
}
{
  const f = fixture(); start(f); f.probe.prepareCallbacks = 4095; f.state.packet = packet(3, 512 + 256);
  f.update(0, f.stateContext, f.iface);
  assert.equal(f.probe.requested, false); assert.match(f.probe.status, /callback limit/);
  assert.equal(f.state.normalWrites, 0);
}
{
  const f = fixture(); f.update(0.02, f.stateContext, f.iface);
  assert.equal(f.state.staticReads || 0, 0, 'idle updates do not query static collision metadata');
  assert.equal(f.state.inputReads, 0, 'idle updates do not poll native input');
  assert.match(f.player.NCCFlightProbeToggle(), /use Start flight/, 'legacy no-argument path cannot bypass preparation');
}
console.log('PASS exploration lifecycle: actual script cancellation/restore plus command-seeded first-click preparation, natural READY, current-state original capture once, deferred dispatch, bounded waits and failed/stale capture refusal');
