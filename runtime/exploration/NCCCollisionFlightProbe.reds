// Experimental 1.8 feasibility probe, installed only in the isolated test profile.
// No gravity changes. A 10-second limit and every normal stop return to start.
// Native state setters returning true do not prove actual collision passage.

class NCCCollisionFlightProbeState extends IScriptable {
  public let validationRequested: Bool;
  public let requested: Bool;
  public let active: Bool;
  public let transitionPending: Bool;
  public let transitionSerial: Uint32;
  public let transitionDeadline: Float;
  public let transitionFacing: EulerAngles;
  public let elapsed: Float;
  public let ticks: Int32;
  public let lastInputPacket: Uint32;
  public let inputChecks: Int32;
  public let filterWrites: Int32;
  public let velocityWrites: Int32;
  public let capturedFilter: Variant;
  public let capturedInterface: wref<StateGameScriptInterface>;
  public let captureWrites: Int32;
  public let ownFilterWrite: Bool;
  public let baselineFilter: Variant;
  public let filterType: CName;
  public let velocityType: CName;
  public let start: Vector4;
  public let target: Vector4;
  public let startFacing: EulerAngles;
  public let stateName: CName;
  public let machineName: CName;
  public let interfaceRef: wref<StateGameScriptInterface>;
  public let status: String;
}

class NCCCollisionFlightTransitionWatchdog extends DelayCallback {
  public let owner: wref<PlayerPuppet>;
  public let expected: wref<NCCCollisionFlightProbeState>;
  public let serial: Uint32;

  public func Call() {
    if IsDefined(this.owner) && IsDefined(this.expected) {
      this.owner.NCCFlightProbeExpireTransition(this.expected, this.serial);
    }
  }
}

@addField(PlayerPuppet)
private let nccCollisionFlightProbe: ref<NCCCollisionFlightProbeState>;

@addMethod(StateGameScriptInterface)
public final func NCCFlightCaptureBegin() -> Uint32 {
  // Native capture bridge returns a nonzero token only for a ready scope.
  return 0u;
}

@addMethod(StateGameScriptInterface)
public final func NCCFlightCaptureEnd() -> Variant {
  // Missing capture support returns an empty value and cannot enable flight.
  let empty: Variant;
  return empty;
}

@addMethod(PlayerPuppet)
public final func NCCFlightInput() -> Uint32 {
  // Native exact-function result bridge replaces only this return value.
  // Default blocks movement and lacks READY, so a missing bridge fails closed.
  return 256u;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeToggle() -> String {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return "Flight refused: validate and capture a normal locomotion filter first";
  }
  if probe.active || probe.requested || probe.transitionPending {
    probe.requested = false;
    probe.status = "Requested: return and restore";
    return probe.status;
  }
  if probe.validationRequested {
    return "Flight refused: read-only validation is still pending";
  }
  if !IsDefined(probe.capturedInterface) || !this.NCCFlightProbeIsFilter(probe.capturedFilter) {
    return "Flight refused: no valid normal collision filter has been captured";
  }
  // The next ordinary update still verifies READY, current-interface identity,
  // grounded stand/crouch, and all setter Variants before enabling movement.
  probe.requested = true;
  probe.status = "Requested: waiting for grounded locomotion";
  return probe.status;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeReturn() -> String {
  if IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe.requested = false;
    this.nccCollisionFlightProbe.status = "Requested: return and restore";
    return this.nccCollisionFlightProbe.status;
  }
  return "Probe has not been requested";
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeValidate() -> String {
  if !IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe = new NCCCollisionFlightProbeState();
  }
  let probe = this.nccCollisionFlightProbe;
  if probe.active || probe.requested || probe.transitionPending {
    return "Validation refused: first stop the flight probe";
  }
  probe.validationRequested = true;
  probe.status = "Read-only validation queued for the next locomotion update";
  return probe.status;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeIsFilter(value: Variant) -> Bool {
  return IsDefined(value) && Equals(VariantTypeName(value), n"physicsSimulationFilter");
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeIsVelocity(value: Variant) -> Bool {
  return IsDefined(value) && Equals(VariantTypeName(value), n"Vector3");
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeZeroFilter() -> Variant {
  let filter: SimulationFilter = SimulationFilter.ZERO();
  return ToVariant(filter);
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeZeroVelocity() -> Variant {
  let velocity: Vector3 = new Vector3(0.0, 0.0, 0.0);
  return ToVariant(velocity);
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeCaptureFilter(scriptInterface: ref<StateGameScriptInterface>, value: Variant) {
  let probe: ref<NCCCollisionFlightProbeState>;
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || !this.NCCFlightProbeIsFilter(value) {
    return;
  }
  if !IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe = new NCCCollisionFlightProbeState();
  }
  probe = this.nccCollisionFlightProbe;
  if probe.ownFilterWrite {
    return;
  }
  // The native setter has accepted the original caller's actual filter. Keep a
  // Variant copy and a weak association with the interface that submitted it.
  probe.capturedFilter = value;
  probe.capturedInterface = scriptInterface;
  probe.captureWrites += 1;
  if probe.active && probe.interfaceRef == scriptInterface {
    probe.baselineFilter = value;
    probe.filterType = VariantTypeName(value);
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeInvalidateCapture(scriptInterface: ref<StateGameScriptInterface>) {
  let probe = this.nccCollisionFlightProbe;
  let empty: Variant;
  if !IsDefined(probe) || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || probe.ownFilterWrite || probe.capturedInterface != scriptInterface {
    return;
  }
  // A failed scope invalidates future activation on this interface. Keep the
  // active restoration baseline separate until the transition handler decides.
  probe.capturedFilter = empty;
  probe.capturedInterface = null;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeWriteFilter(scriptInterface: ref<StateGameScriptInterface>, value: Variant) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  let previousOwnWrite: Bool;
  let accepted: Bool;
  if !IsDefined(probe) || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || !this.NCCFlightProbeIsFilter(value) {
    return false;
  }
  previousOwnWrite = probe.ownFilterWrite;
  probe.ownFilterWrite = true;
  accepted = scriptInterface.SetStateVectorParameter(physicsStateValue.SimulationFilter, value);
  probe.ownFilterWrite = previousOwnWrite;
  return accepted;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeRunValidation(scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName) {
  let probe = this.nccCollisionFlightProbe;
  let baseline: Variant;
  let zeroFilter: Variant;
  let velocityRead: Variant;
  let zeroVelocity: Variant;
  if !IsDefined(probe) || !probe.validationRequested {
    return;
  }
  probe.validationRequested = false;
  if probe.active || probe.requested || probe.transitionPending {
    probe.status = "Validation refused: flight is no longer idle";
    return;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this {
    probe.status = "Validation refused: locomotion owner changed";
    return;
  }
  probe.stateName = stateName;
  probe.machineName = machineName;
  probe.lastInputPacket = this.NCCFlightInput();
  probe.inputChecks += 1;
  // Native 2.5 getter switch maps SimulationFilter to its empty return path.
  // Inspecting it is safe; sending that empty Variant back to the setter is not.
  baseline = scriptInterface.GetStateVectorParameter(physicsStateValue.SimulationFilter);
  zeroFilter = this.NCCFlightProbeZeroFilter();
  velocityRead = scriptInterface.GetStateVectorParameter(physicsStateValue.LinearVelocity);
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  probe.filterType = VariantTypeName(probe.capturedFilter);
  probe.velocityType = VariantTypeName(velocityRead);
  probe.status = "Read-only validation: ready=" + ToString((probe.lastInputPacket & 512u) != 0u)
    + "; unsupportedGetter=" + NameToString(VariantTypeName(baseline)) + "/defined=" + ToString(IsDefined(baseline))
    + "; capturedFilter=" + NameToString(VariantTypeName(probe.capturedFilter)) + "/defined=" + ToString(IsDefined(probe.capturedFilter))
    + "; captureValid=" + ToString(this.NCCFlightProbeIsFilter(probe.capturedFilter))
    + "; captureCurrent=" + ToString(IsDefined(probe.capturedInterface) && probe.capturedInterface == scriptInterface)
    + "; zeroFilter=" + NameToString(VariantTypeName(zeroFilter)) + "/defined=" + ToString(IsDefined(zeroFilter))
    + "; velocityRead=" + NameToString(VariantTypeName(velocityRead)) + "/defined=" + ToString(IsDefined(velocityRead))
    + "; zeroVelocity=" + NameToString(VariantTypeName(zeroVelocity)) + "/defined=" + ToString(IsDefined(zeroVelocity))
    + "; validFilters=" + ToString(this.NCCFlightProbeIsFilter(probe.capturedFilter) && this.NCCFlightProbeIsFilter(zeroFilter))
    + "; validVelocity=" + ToString(this.NCCFlightProbeIsVelocity(zeroVelocity))
    + "; no physics writes or teleports";
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeStatus() -> String {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return "Probe has not been requested";
  }
  return probe.status + "; active=" + ToString(probe.active)
    + "; validationRequested=" + ToString(probe.validationRequested)
    + "; transitionPending=" + ToString(probe.transitionPending)
    + "; requested=" + ToString(probe.requested)
    + "; ticks=" + ToString(probe.ticks)
    + "; lastInputPacket=" + ToString(probe.lastInputPacket)
    + "; inputChecks=" + ToString(probe.inputChecks)
    + "; captureWrites=" + ToString(probe.captureWrites)
    + "; filterWrites=" + ToString(probe.filterWrites)
    + "; velocityWrites=" + ToString(probe.velocityWrites)
    + "; filterType=" + NameToString(probe.filterType)
    + "; velocityType=" + NameToString(probe.velocityType)
    + "; state=" + NameToString(probe.stateName)
    + "; machine=" + NameToString(probe.machineName);
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeAllowed(stateName: CName, machineName: CName) -> Bool {
  return Equals(machineName, n"Locomotion")
    && (Equals(stateName, n"stand") || Equals(stateName, n"crouch")
      || Equals(stateName, n"preCrouch") || Equals(stateName, n"sprint")
      || Equals(stateName, n"sprintWindup") || Equals(stateName, n"fall")
      || Equals(stateName, n"jump"));
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeRestore(scriptInterface: ref<StateGameScriptInterface>, reason: String, returnToStart: Bool) {
  let probe = this.nccCollisionFlightProbe;
  let zeroVelocity: Variant;
  if !IsDefined(probe) {
    return;
  }
  probe.requested = false;
  if !probe.active {
    // An ordinary exit has already returned to the safe start and restored
    // collision. Do not overwrite a new state's filter through an old context.
    probe.transitionPending = false;
    probe.status = reason;
    return;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || probe.interfaceRef != scriptInterface {
    probe.status = "Restore refused: owner changed";
    return;
  }
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  if !this.NCCFlightProbeIsFilter(probe.baselineFilter) || !this.NCCFlightProbeIsVelocity(zeroVelocity) {
    probe.status = "Restore refused: invalid collision or velocity Variant; no physics writes";
    return;
  }
  if returnToStart && !this.IsDead() && !scriptInterface.IsMountedToObject() {
    GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.start, probe.startFacing);
  }
  scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity);
  if this.NCCFlightProbeWriteFilter(scriptInterface, probe.baselineFilter) {
    probe.active = false;
    probe.transitionPending = false;
    probe.status = reason + "; filter restored";
    probe.interfaceRef = null;
  } else {
    probe.status = "Restore failed: awaiting next locomotion update";
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeExpireTransition(expected: wref<NCCCollisionFlightProbeState>, serial: Uint32) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && probe == expected && probe.transitionPending && probe.transitionSerial == serial {
    probe.transitionPending = false;
    probe.requested = false;
    probe.status = "Stopped at activation point: no immediate allowed state transition";
    probe.interfaceRef = null;
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeSuspendForTransition(scriptInterface: ref<StateGameScriptInterface>) {
  let probe = this.nccCollisionFlightProbe;
  let resume: Bool;
  let watchdog: ref<NCCCollisionFlightTransitionWatchdog>;
  if !IsDefined(probe) || !probe.active {
    return;
  }
  resume = probe.requested;
  probe.transitionFacing = Quaternion.ToEulerAngles(this.GetWorldOrientation());
  this.NCCFlightProbeRestore(scriptInterface, "Returned and restored for locomotion exit", true);
  if !probe.active && resume {
    probe.requested = true;
    probe.transitionPending = true;
    probe.transitionSerial += 1u;
    probe.transitionDeadline = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())) + 0.05;
    watchdog = new NCCCollisionFlightTransitionWatchdog();
    watchdog.owner = this;
    watchdog.expected = probe;
    watchdog.serial = probe.transitionSerial;
    GameInstance.GetDelaySystem(this.GetGame()).DelayCallbackNextFrame(watchdog);
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeObserveStateFilter(scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName, capturedFresh: Bool) {
  let probe = this.nccCollisionFlightProbe;
  let chosenFilter: Variant;
  let zeroFilter: Variant;
  let zeroVelocity: Variant;
  let resuming: Bool;
  if !IsDefined(probe) || (!probe.active && !probe.transitionPending) {
    return;
  }
  // A bounded native scope captured the original state method's successful
  // filter write before this callback. The native getter cannot read it back.
  chosenFilter = probe.capturedFilter;
  zeroFilter = this.NCCFlightProbeZeroFilter();
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  if !capturedFresh || !IsDefined(probe.capturedInterface) || probe.capturedInterface != scriptInterface
    || !this.NCCFlightProbeIsFilter(chosenFilter) || !this.NCCFlightProbeIsFilter(zeroFilter)
    || !this.NCCFlightProbeIsVelocity(zeroVelocity) {
    // The original method has selected the next state's filter. Never replace
    // that value with ZERO if its actual restoration value cannot be read.
    probe.status = "Stopped: fresh collision capture failed; native filter retained";
    if probe.active && IsDefined(scriptInterface) && scriptInterface.owner == this
      && !this.IsDead() && !scriptInterface.IsMountedToObject() {
      GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.start, probe.startFacing);
      probe.status = "Stopped: fresh collision capture failed; return requested; native filter retained";
    }
    probe.requested = false;
    probe.active = false;
    probe.transitionPending = false;
    probe.interfaceRef = null;
    return;
  }
  probe.baselineFilter = chosenFilter;
  probe.filterType = VariantTypeName(probe.baselineFilter);
  probe.stateName = stateName;
  probe.machineName = machineName;
  probe.interfaceRef = scriptInterface;
  if !probe.requested || !this.NCCFlightProbeAllowed(stateName, machineName)
    || this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive() || (this.NCCFlightInput() & 512u) == 0u
    || (probe.transitionPending && EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())) > probe.transitionDeadline) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped for locomotion transition", true);
    return;
  }
  if this.NCCFlightProbeWriteFilter(scriptInterface, zeroFilter) {
    resuming = probe.transitionPending;
    probe.transitionPending = false;
    probe.active = true;
    probe.filterWrites += 1;
    if resuming {
      // Both teleports are issued from the same simulation callback chain. The
      // exit return guarantees safety if no allowed next state ever arrives.
      // Actual native teleport/camera ordering is still a live-probe question.
      GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.target, probe.transitionFacing);
    }
  } else {
    this.NCCFlightProbeRestore(scriptInterface, "Collision setter rejected state transition", true);
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName) {
  let probe = this.nccCollisionFlightProbe;
  let movement: Vector4;
  let speed: Float;
  let dt: Float;
  let packet: Uint32;
  let horizontal: Float;
  let forward: Float;
  let vertical: Float;
  let blocked: Bool;
  let zeroFilter: Variant;
  let zeroVelocity: Variant;
  if !IsDefined(probe) {
    return;
  }
  if probe.active && (!IsDefined(scriptInterface) || scriptInterface.owner != this
    || probe.interfaceRef != scriptInterface) {
    // Never apply an old state's baseline or ZERO through a different context.
    // Only request the safe return when the current context still owns us.
    probe.status = "Stopped: locomotion context changed; new state filter untouched";
    if IsDefined(scriptInterface) && scriptInterface.owner == this
      && !this.IsDead() && !scriptInterface.IsMountedToObject() {
      GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.start, probe.startFacing);
      probe.status = "Stopped: locomotion context changed; return requested; new state filter untouched";
    }
    probe.requested = false;
    probe.active = false;
    probe.transitionPending = false;
    probe.interfaceRef = null;
    return;
  }
  if probe.validationRequested {
    this.NCCFlightProbeRunValidation(scriptInterface, stateName, machineName);
    return;
  }
  if !probe.requested && !probe.active {
    return;
  }
  if probe.transitionPending {
    this.NCCFlightProbeExpireTransition(probe, probe.transitionSerial);
    return;
  }
  probe.stateName = stateName;
  probe.machineName = machineName;
  packet = this.NCCFlightInput();
  probe.lastInputPacket = packet;
  probe.inputChecks += 1;
  if (packet & 512u) == 0u {
    this.NCCFlightProbeRestore(scriptInterface, "Input bridge is not ready", true);
    return;
  }
  blocked = (packet & 256u) != 0u
    || GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_System).GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
  if this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive() || !this.NCCFlightProbeAllowed(stateName, machineName) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped for unsupported player state", true);
    return;
  }
  if !probe.requested {
    this.NCCFlightProbeRestore(scriptInterface, "Returned to activation point", true);
    return;
  }
  zeroFilter = this.NCCFlightProbeZeroFilter();
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  if !this.NCCFlightProbeIsFilter(zeroFilter) || !this.NCCFlightProbeIsVelocity(zeroVelocity) {
    this.NCCFlightProbeRestore(scriptInterface, "Activation refused: invalid zero filter or velocity Variant", true);
    return;
  }
  if !probe.active {
    if !scriptInterface.IsOnGround() || !(Equals(stateName, n"stand") || Equals(stateName, n"crouch")) {
      probe.status = "Waiting for grounded stand/crouch";
      return;
    }
    probe.baselineFilter = probe.capturedFilter;
    probe.filterType = VariantTypeName(probe.baselineFilter);
    if !IsDefined(probe.capturedInterface) || probe.capturedInterface != scriptInterface
      || !this.NCCFlightProbeIsFilter(probe.baselineFilter) {
      probe.requested = false;
      probe.status = "Activation refused: no valid collision filter captured for this interface";
      return;
    }
    probe.velocityType = VariantTypeName(scriptInterface.GetStateVectorParameter(physicsStateValue.LinearVelocity));
    probe.start = this.GetWorldPosition();
    probe.target = probe.start;
    probe.startFacing = Quaternion.ToEulerAngles(this.GetWorldOrientation());
    probe.elapsed = 0.0;
    probe.ticks = 0;
    probe.filterWrites = 0;
    probe.velocityWrites = 0;
    probe.interfaceRef = scriptInterface;
    if !this.NCCFlightProbeWriteFilter(scriptInterface, zeroFilter) {
      probe.requested = false;
      probe.status = "Collision setter rejected activation";
      return;
    }
    probe.active = true;
  }
  probe.elapsed += MaxF(timeDelta, 0.0);
  if probe.elapsed >= 10.0 {
    this.NCCFlightProbeRestore(scriptInterface, "10-second probe complete", true);
    return;
  }
  dt = ClampF(timeDelta, 0.0, 0.05);
  if !blocked {
    if (packet & 1u) != 0u { forward += 1.0; }
    if (packet & 2u) != 0u { forward -= 1.0; }
    if (packet & 4u) != 0u { horizontal -= 1.0; }
    if (packet & 8u) != 0u { horizontal += 1.0; }
    if (packet & 16u) != 0u { vertical += 1.0; }
    if (packet & 32u) != 0u { vertical -= 1.0; }
  }
  movement = scriptInterface.GetCameraSystem().GetActiveCameraRight() * horizontal
    + scriptInterface.GetCameraSystem().GetActiveCameraForward() * forward
    + new Vector4(0.0, 0.0, vertical, 0.0);
  movement.W = 0.0;
  if Vector4.Length(movement) > 1.0 {
    movement = Vector4.Normalize(movement);
  }
  speed = (packet & 64u) != 0u ? 12.0 : 4.0;
  if (packet & 128u) != 0u { speed = 0.75; }
  probe.target += movement * (speed * dt);
  probe.target.W = 1.0;
  if !this.NCCFlightProbeIsFilter(probe.baselineFilter) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped: collision baseline became invalid", true);
    return;
  }
  if !this.NCCFlightProbeWriteFilter(scriptInterface, zeroFilter) {
    this.NCCFlightProbeRestore(scriptInterface, "Collision setter rejected update", true);
    return;
  }
  probe.filterWrites += 1;
  GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.target, Quaternion.ToEulerAngles(this.GetWorldOrientation()));
  if scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity) {
    probe.velocityWrites += 1;
  } else {
    this.NCCFlightProbeRestore(scriptInterface, "Velocity setter rejected update", true);
    return;
  }
  probe.ticks += 1;
  probe.status = "Active collision/velocity probe";
}

@wrapMethod(LocomotionEventsTransition)
public func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
  wrappedMethod(timeDelta, stateContext, scriptInterface);
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(player) {
    player.NCCFlightProbeUpdate(timeDelta, stateContext, scriptInterface, this.GetStateName(), this.GetStateMachineName());
  }
}

@wrapMethod(LocomotionTransition)
public final func SetCollisionFilter(scriptInterface: ref<StateGameScriptInterface>) {
  let captureToken = scriptInterface.NCCFlightCaptureBegin();
  wrappedMethod(scriptInterface);
  let capturedFilter = scriptInterface.NCCFlightCaptureEnd();
  let capturedFresh = captureToken != 0u && IsDefined(capturedFilter)
    && Equals(VariantTypeName(capturedFilter), n"physicsSimulationFilter");
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(player) {
    if capturedFresh {
      player.NCCFlightProbeCaptureFilter(scriptInterface, capturedFilter);
    } else {
      player.NCCFlightProbeInvalidateCapture(scriptInterface);
    }
    player.NCCFlightProbeObserveStateFilter(scriptInterface, this.GetStateName(), this.GetStateMachineName(), capturedFresh);
  }
}

@wrapMethod(LocomotionEventsTransition)
public func OnExit(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(player) {
    player.NCCFlightProbeSuspendForTransition(scriptInterface);
  }
  wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(LocomotionEventsTransition)
public func OnForcedExit(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(player) {
    player.NCCFlightProbeRestore(scriptInterface, "Forced locomotion exit", true);
  }
  wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(PlayerPuppet)
protected cb func OnDetach() -> Bool {
  // No attempt to teleport or operate through an old interface during teardown.
  if IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe.capturedInterface = null;
    this.nccCollisionFlightProbe.interfaceRef = null;
  }
  this.nccCollisionFlightProbe = null;
  return wrappedMethod();
}
