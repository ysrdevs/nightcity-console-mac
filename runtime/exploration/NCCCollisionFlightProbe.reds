// Experimental 1.8 feasibility probe, installed only in the isolated test profile.
// No gravity changes. A 30-second limit and every normal stop return to start.
// Native state setters returning true do not prove actual collision passage.

class NCCCollisionFlightProbeState extends IScriptable {
  public let requested: Bool;
  public let active: Bool;
  public let transitionPending: Bool;
  public let transitionSerial: Uint32;
  public let transitionDeadline: Float;
  public let transitionFacing: EulerAngles;
  public let elapsed: Float;
  public let ticks: Int32;
  public let filterWrites: Int32;
  public let velocityWrites: Int32;
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

@addMethod(PlayerPuppet)
public final func NCCFlightInput() -> Uint32 {
  // Native exact-function result bridge replaces only this return value.
  // Default blocks movement and lacks READY, so a missing bridge fails closed.
  return 256u;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeToggle() -> String {
  if !IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe = new NCCCollisionFlightProbeState();
  }
  this.nccCollisionFlightProbe.requested = !this.nccCollisionFlightProbe.requested;
  this.nccCollisionFlightProbe.status = this.nccCollisionFlightProbe.requested ? "Requested: waiting for grounded locomotion" : "Requested: return and restore";
  return this.nccCollisionFlightProbe.status;
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
public final func NCCFlightProbeStatus() -> String {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return "Probe has not been requested";
  }
  return probe.status + "; active=" + ToString(probe.active)
    + "; transitionPending=" + ToString(probe.transitionPending)
    + "; requested=" + ToString(probe.requested)
    + "; ticks=" + ToString(probe.ticks)
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
  if !IsDefined(scriptInterface) || scriptInterface.owner != this {
    probe.status = "Restore refused: owner changed";
    return;
  }
  if returnToStart && !this.IsDead() && !scriptInterface.IsMountedToObject() {
    GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.start, probe.startFacing);
  }
  scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, ToVariant(new Vector3(0.0, 0.0, 0.0)));
  if scriptInterface.SetStateVectorParameter(physicsStateValue.SimulationFilter, probe.baselineFilter) {
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
public final func NCCFlightProbeObserveStateFilter(scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName) {
  let probe = this.nccCollisionFlightProbe;
  let chosenFilter: Variant;
  let resuming: Bool;
  if !IsDefined(probe) || (!probe.active && !probe.transitionPending) {
    return;
  }
  // The original state method has just chosen its actual filter. Preserve that
  // exact Variant as the current state's restoration value before overriding it.
  chosenFilter = scriptInterface.GetStateVectorParameter(physicsStateValue.SimulationFilter);
  if NotEquals(VariantTypeName(chosenFilter), VariantTypeName(ToVariant(SimulationFilter.ZERO()))) {
    // The original method has selected the next state's filter. Never replace
    // that value with ZERO if its actual restoration value cannot be read.
    probe.requested = false;
    if probe.active && !this.IsDead() && !scriptInterface.IsMountedToObject() {
      GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.start, probe.startFacing);
    }
    probe.active = false;
    probe.transitionPending = false;
    probe.status = "Stopped: new state filter could not be read; native filter retained";
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
  if scriptInterface.SetStateVectorParameter(physicsStateValue.SimulationFilter, ToVariant(SimulationFilter.ZERO())) {
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
  if !IsDefined(probe) || (!probe.requested && !probe.active) {
    return;
  }
  if probe.transitionPending {
    this.NCCFlightProbeExpireTransition(probe, probe.transitionSerial);
    return;
  }
  probe.stateName = stateName;
  probe.machineName = machineName;
  packet = this.NCCFlightInput();
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
  if !probe.active {
    if !scriptInterface.IsOnGround() || !(Equals(stateName, n"stand") || Equals(stateName, n"crouch")) {
      probe.status = "Waiting for grounded stand/crouch";
      return;
    }
    probe.baselineFilter = scriptInterface.GetStateVectorParameter(physicsStateValue.SimulationFilter);
    probe.filterType = VariantTypeName(probe.baselineFilter);
    if NotEquals(probe.filterType, VariantTypeName(ToVariant(SimulationFilter.ZERO()))) {
      probe.requested = false;
      probe.status = "Activation refused: collision baseline has unexpected type";
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
    if !scriptInterface.SetStateVectorParameter(physicsStateValue.SimulationFilter, ToVariant(SimulationFilter.ZERO())) {
      probe.requested = false;
      probe.status = "Collision setter rejected activation";
      return;
    }
    probe.active = true;
  }
  probe.elapsed += MaxF(timeDelta, 0.0);
  if probe.elapsed >= 30.0 {
    this.NCCFlightProbeRestore(scriptInterface, "30-second probe complete", true);
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
  if !scriptInterface.SetStateVectorParameter(physicsStateValue.SimulationFilter, ToVariant(SimulationFilter.ZERO())) {
    this.NCCFlightProbeRestore(scriptInterface, "Collision setter rejected update", true);
    return;
  }
  probe.filterWrites += 1;
  GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.target, Quaternion.ToEulerAngles(this.GetWorldOrientation()));
  if scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, ToVariant(new Vector3(0.0, 0.0, 0.0))) {
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
  wrappedMethod(scriptInterface);
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(player) {
    player.NCCFlightProbeObserveStateFilter(scriptInterface, this.GetStateName(), this.GetStateMachineName());
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
  this.nccCollisionFlightProbe = null;
  return wrappedMethod();
}
