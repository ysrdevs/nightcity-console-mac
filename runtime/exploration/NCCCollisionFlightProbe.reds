// Experimental 1.8 feasibility probe, installed only in the isolated test profile.
// No gravity changes. Stop here restores clear collision; Return is explicit.
// Native state setters returning true do not prove actual collision passage.

// Temporary, explicitly armed camera diagnostics. Objects are allocated once
// when requested; ordinary frames do not allocate samples or format/log text.
class NCCFlightCameraSample extends IScriptable {
  public let frame: Int32;
  public let time: Float;
  public let dt: Float;
  public let packet: Uint32;
  public let previousC: Vector4;
  public let inputA: Vector4;
  public let inputB: Vector4;
  public let inputC: Vector4;
  public let anglesA: Vector4;
  public let anglesB: Vector4;
  public let anglesC: Vector4;
}

class NCCFlightCameraWindow extends IScriptable {
  public let samples: array<ref<NCCFlightCameraSample>>;
  public let count: Int32;
  public let frames: Int32;
  public let running: Bool;
  public let frameOpen: Bool;
  public let originRead: Bool;
  public let positionDefined: Bool;
  public let positionType: CName;
  public let physicsPosition: Vector4;
  public let entityPosition: Vector4;
  public let elapsed: Float;
  public let duration: Float;
  public let nextSample: Float;
  public let dt: Float;
  public let packet: Uint32;
  public let horizontalFrames: Int32;
  public let verticalFrames: Int32;
  public let yawTravelAB: Float;
  public let yawTravelBC: Float;
  public let yawTravelNextA: Float;
  public let previousC: Vector4;
  public let inputA: Vector4;
  public let inputB: Vector4;
  public let inputC: Vector4;
  public let anglesA: Vector4;
  public let anglesB: Vector4;
  public let anglesC: Vector4;

  public final func Initialize(capacity: Int32, seconds: Float) {
    let i = 0;
    this.duration = seconds;
    while i < capacity {
      ArrayPush(this.samples, new NCCFlightCameraSample());
      i += 1;
    }
  }

  public final func ReadOrigin(player: ref<PlayerPuppet>, scriptInterface: ref<StateGameScriptInterface>) {
    let value = scriptInterface.GetStateVectorParameter(physicsStateValue.Position);
    this.positionType = VariantTypeName(value);
    this.positionDefined = IsDefined(value) && Equals(this.positionType, n"Vector4");
    if this.positionDefined {
      this.physicsPosition = FromVariant<Vector4>(value);
    }
    this.entityPosition = player.GetWorldPosition();
    this.originRead = true;
  }

  public final func Capture(player: ref<PlayerPuppet>, scriptInterface: ref<StateGameScriptInterface>, phase: Int32) {
    let camera = scriptInterface.GetCameraWorldTransform();
    let angles = new Vector4(player.GetWorldYaw(), Transform.GetYaw(camera), Transform.GetPitch(camera), 0.0);
    let input = new Vector4(scriptInterface.GetActionValue(n"CameraMouseX"), scriptInterface.GetActionValue(n"CameraX"),
      scriptInterface.GetActionValue(n"CameraMouseY"), scriptInterface.GetActionValue(n"CameraY"));
    if phase == 0 {
      this.anglesA = angles;
      this.inputA = input;
    } else {
      if phase == 1 {
        this.anglesB = angles;
        this.inputB = input;
      } else {
        this.anglesC = angles;
        this.inputC = input;
      }
    }
  }

  public final func Finish() {
    let sample: ref<NCCFlightCameraSample>;
    if !this.frameOpen {
      return;
    }
    this.frameOpen = false;
    if this.inputA.X != 0.0 || this.inputA.Y != 0.0 || this.inputB.X != 0.0 || this.inputB.Y != 0.0
      || this.inputC.X != 0.0 || this.inputC.Y != 0.0 {
      this.horizontalFrames += 1;
    }
    if this.inputA.Z != 0.0 || this.inputA.W != 0.0 || this.inputB.Z != 0.0 || this.inputB.W != 0.0
      || this.inputC.Z != 0.0 || this.inputC.W != 0.0 {
      this.verticalFrames += 1;
    }
    this.yawTravelAB += AbsF(AngleNormalize180(this.anglesB.Y - this.anglesA.Y));
    this.yawTravelBC += AbsF(AngleNormalize180(this.anglesC.Y - this.anglesB.Y));
    if this.frames > 0 {
      this.yawTravelNextA += AbsF(AngleNormalize180(this.anglesA.Y - this.previousC.Y));
    }
    if this.count < ArraySize(this.samples) && this.elapsed >= this.nextSample {
      sample = this.samples[this.count];
      sample.frame = this.frames;
      sample.time = this.elapsed;
      sample.dt = this.dt;
      sample.packet = this.packet;
      sample.previousC = this.previousC;
      sample.inputA = this.inputA;
      sample.inputB = this.inputB;
      sample.inputC = this.inputC;
      sample.anglesA = this.anglesA;
      sample.anglesB = this.anglesB;
      sample.anglesC = this.anglesC;
      this.count += 1;
      this.nextSample = Cast<Float>(this.count) * this.duration / Cast<Float>(ArraySize(this.samples));
    }
    this.previousC = this.anglesC;
    this.frames += 1;
    this.elapsed += this.dt;
    // Simulation time may stop advancing. Also bound the number of callbacks.
    if this.elapsed >= this.duration || this.frames >= 4096 {
      this.running = false;
    }
  }

  private final func FormatVector(value: Vector4) -> String {
    return FloatToStringPrec(value.X, 3) + "," + FloatToStringPrec(value.Y, 3)
      + "," + FloatToStringPrec(value.Z, 3) + "," + FloatToStringPrec(value.W, 3);
  }

  public final func Report(label: String) -> String {
    let i = 0;
    let sample: ref<NCCFlightCameraSample>;
    let report = "\nCamera " + label + ": running=" + ToString(this.running)
      + " frames=" + ToString(this.frames) + " seconds=" + FloatToStringPrec(this.elapsed, 3)
      + " rows=" + ToString(this.count) + " horizontalFrames=" + ToString(this.horizontalFrames)
      + " verticalFrames=" + ToString(this.verticalFrames)
      + " cameraYawTravel[AB,BC,nextA]=" + FloatToStringPrec(this.yawTravelAB, 3)
      + "," + FloatToStringPrec(this.yawTravelBC, 3) + "," + FloatToStringPrec(this.yawTravelNextA, 3)
      + "\noriginRead=" + ToString(this.originRead) + " physicsPosition=" + NameToString(this.positionType)
      + "/validVector4=" + ToString(this.positionDefined) + ":" + this.FormatVector(this.physicsPosition)
      + " entityPosition=" + this.FormatVector(this.entityPosition)
      + "\nrow frame t dt packet previousC; Ainput Aangles; Binput Bangles; Cinput Cangles"
      + " (input=MouseX,CameraX,MouseY,CameraY; angles=bodyYaw,cameraYaw,cameraPitch,0; previousC=immediately prior frame)";
    while i < this.count {
      sample = this.samples[i];
      report += "\n" + ToString(sample.frame) + " " + FloatToStringPrec(sample.time, 3)
        + " " + FloatToStringPrec(sample.dt, 3) + " " + ToString(sample.packet)
        + " " + this.FormatVector(sample.previousC)
        + "; " + this.FormatVector(sample.inputA) + " " + this.FormatVector(sample.anglesA)
        + "; " + this.FormatVector(sample.inputB) + " " + this.FormatVector(sample.anglesB)
        + "; " + this.FormatVector(sample.inputC) + " " + this.FormatVector(sample.anglesC);
      i += 1;
    }
    return report;
  }
}

class NCCFlightTransitionSample extends IScriptable {
  public let phase: CName;
  public let time: Float;
  public let dt: Float;
  public let callback: Int32;
  public let serial: Uint32;
  public let fromState: CName;
  public let fromMachine: CName;
  public let toState: CName;
  public let toMachine: CName;
  public let owned: Bool;
  public let physicsValid: Bool;
  public let physicsType: CName;
  public let physics: Vector4;
  public let entity: Vector4;
  public let target: Vector4;
  public let expected: Vector4;
  public let recovery: Vector4;
  public let error: Vector4;
  public let pending: Bool;
  public let active: Bool;
  public let paused: Bool;
  public let handoff: Bool;
  public let writes: Int32;
  public let captures: Int32;
}

class NCCFlightTransitionTrace extends IScriptable {
  public let samples: array<ref<NCCFlightTransitionSample>>;
  public let next: Int32;
  public let count: Int32;
  public let events: Int32;
  public let callbacks: Int32;
  public let elapsed: Float;
  public let lastDelta: Float;
  public let watch: Int32;
  public let running: Bool;
  public let stop: CName;
  public let fromState: CName;
  public let fromMachine: CName;
  public let toState: CName;
  public let toMachine: CName;
  public let recovery: Vector4;

  public func TraceInitialize() {
    let i = 0;
    this.next = 0;
    this.count = 0;
    this.events = 0;
    this.callbacks = 0;
    this.elapsed = 0.0;
    this.lastDelta = 0.0;
    this.watch = 0;
    this.running = false;
    this.stop = n"awaiting-activation";
    while i < 32 {
      ArrayPush(this.samples, new NCCFlightTransitionSample());
      i += 1;
    }
  }

  public func TraceAdvance(dt: Float) -> Bool {
    if !this.running { return false; }
    this.callbacks += 1;
    this.lastDelta = dt;
    if dt >= 0.0 && dt <= 1.0 { this.elapsed += dt; }
    if this.callbacks >= 4096 || this.elapsed >= 30.0 {
      this.TraceFreeze(n"budget");
      return false;
    }
    return true;
  }

  public func TraceNext() -> ref<NCCFlightTransitionSample> {
    let sample: ref<NCCFlightTransitionSample>;
    if !this.TraceAvailable() { return null; }
    this.events += 1;
    sample = this.samples[this.next];
    this.next += 1;
    if this.next == 32 { this.next = 0; }
    if this.count < 32 { this.count += 1; }
    return sample;
  }

  public func TraceAvailable() -> Bool {
    if !this.running { return false; }
    if this.events >= 8192 || ArraySize(this.samples) != 32 {
      this.TraceFreeze(n"event-budget");
      return false;
    }
    return true;
  }

  public func TraceFreeze(reason: CName) {
    if this.running {
      this.running = false;
      this.stop = reason;
    }
  }

  private func TraceVector(value: Vector4) -> String {
    return FloatToStringPrec(value.X, 4) + "," + FloatToStringPrec(value.Y, 4) + "," + FloatToStringPrec(value.Z, 4);
  }

  public func TraceReport() -> String {
    let report = "\nTransition trace: running=" + ToString(this.running) + " stop=" + NameToString(this.stop)
      + " callbacks=" + ToString(this.callbacks) + "/4096 seconds=" + FloatToStringPrec(this.elapsed, 3)
      + "/30 retained=" + ToString(this.count) + "/32"
      + " events=" + ToString(this.events) + "/8192"
      + "\nphase simTime latestUpdateDt frame serial from>to owned/physics/type active/paused/handoff pending writes captures; physics; entity; target; expected; recovery; signedXYZerror";
    let i = 0;
    let index = this.next - this.count;
    let sample: ref<NCCFlightTransitionSample>;
    if index < 0 { index += 32; }
    while i < this.count {
      sample = this.samples[index];
      report += "\n" + NameToString(sample.phase) + " " + FloatToStringPrec(sample.time, 4)
        + " " + FloatToStringPrec(sample.dt, 4) + " " + ToString(sample.callback) + " " + ToString(sample.serial)
        + " " + NameToString(sample.fromMachine) + "/" + NameToString(sample.fromState)
        + ">" + NameToString(sample.toMachine) + "/" + NameToString(sample.toState)
        + " " + ToString(sample.owned) + "/" + ToString(sample.physicsValid) + "/" + NameToString(sample.physicsType)
        + " " + ToString(sample.active) + "/" + ToString(sample.paused) + "/" + ToString(sample.handoff)
        + " " + ToString(sample.pending) + " " + ToString(sample.writes) + " " + ToString(sample.captures)
        + "; " + this.TraceVector(sample.physics) + "; " + this.TraceVector(sample.entity)
        + "; " + this.TraceVector(sample.target) + "; " + this.TraceVector(sample.expected)
        + "; " + this.TraceVector(sample.recovery) + "; " + this.TraceVector(sample.error);
      index += 1;
      if index == 32 { index = 0; }
      i += 1;
    }
    return report;
  }
}

class NCCCollisionFlightProbeState extends IScriptable {
  public let validationRequested: Bool;
  public let requested: Bool;
  public let preparePending: Bool;
  public let prepared: Bool;
  public let prepareCallbacks: Int32;
  public let prepareElapsed: Float;
  public let prepareCaptureBefore: Int32;
  public let preparedInterface: wref<StateGameScriptInterface>;
  public let preparedState: CName;
  public let preparedMachine: CName;
  public let capsuleHeight: Float;
  public let capsuleRadius: Float;
  public let active: Bool;
  public let paused: Bool;
  public let pauseReason: String;
  public let resumeRequested: Bool;
  public let exitRequest: Int32;
  public let processingExitRequest: Int32;
  public let lastAcceptedControl: CName;
  public let lastClearValid: Bool;
  public let lastClearPosition: Vector4;
  public let lastClearFacing: EulerAngles;
  public let clearanceClock: Float;
  public let lastClearanceProbePosition: Vector4;
  public let clearanceProbes: Int32;
  public let recoveryUsed: Bool;
  public let restoreMoved: Bool;
  public let arrivalUnconfirmed: Bool;
  public let arrivalPending: Bool;
  public let arrivalOwner: wref<PlayerPuppet>;
  public let arrivalDestination: Vector4;
  public let arrivalSubmittedPosition: Vector4;
  public let arrivalTolerance: Float;
  public let arrivalOriginDelta: Vector4;
  public let arrivalIssuedAt: Float;
  public let arrivalPollStartedAt: Float;
  public let arrivalElapsed: Float;
  public let arrivalCallbacks: Int32;
  public let arrivalSerial: Int32;
  public let arrivalDistance: Float;
  public let arrivalReason: String;
  public let arrivalControl: CName;
  public let arrivalExitIntent: Int32;
  public let arrivalProcessingExitIntent: Int32;
  public let arrivalWasPaused: Bool;
  public let arrivalWasRequested: Bool;
  public let arrivalInteractionFlags: Int32;
  public let arrivalMenuOpen: Bool;
  public let arrivalPreviousTarget: Vector4;
  public let arrivalPreviousReadbackPending: Bool;
  public let arrivalPreviousReadbackDistance: Float;
  public let arrivalPreviousOriginDivergence: Float;
  public let arrivalFailureReason: String;
  public let arrivalFailureCallbacks: Int32;
  public let arrivalFailureElapsed: Float;
  public let arrivalObservationValid: Bool;
  public let arrivalObservedAt: Float;
  public let arrivalObservedState: CName;
  public let arrivalObservedMachine: CName;
  public let arrivalObservedEntity: Vector4;
  public let arrivalObservedPhysics: Vector4;
  public let arrivalRestoreInterface: wref<StateGameScriptInterface>;
  public let arrivalRestoreFilter: Variant;
  public let arrivalRestoreCapture: Int32;
  public let arrivalRestoreState: CName;
  public let arrivalRestoreMachine: CName;
  public let interactionYield: Bool;
  public let interactionFlags: Int32;
  public let interactionReason: String;
  public let interactionRestoreInterface: wref<StateGameScriptInterface>;
  public let interactionRestoreFilter: Variant;
  public let interactionRestoreCapture: Int32;
  public let clearanceFailed: Bool;
  public let exitObservedPosition: Vector4;
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
  public let positionWritesIssued: Int32;
  public let positionReadbacks: Int32;
  public let positionRefusals: Int32;
  public let positionReadbackPending: Bool;
  public let positionReadbackDistance: Float;
  public let positionOriginDivergence: Float;
  public let maxPositionReadbackDistance: Float;
  public let maxPositionOriginDivergence: Float;
  public let maxObservedEntityRadius: Float;
  public let lastIssuedTargetRadius: Float;
  public let positionOriginDelta: Vector4;
  public let positionLastTarget: Vector4;
  public let positionLastRefusal: String;
  public let capturedFilter: Variant;
  public let capturedNormal: Bool;
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
  public let stopRequested: Bool;
  public let stopReason: String;
  public let restoreUnconfirmed: Bool;
  public let menuOpen: Bool;
  public let menuBlackboard: wref<IBlackboard>;
  public let menuListener: ref<CallbackHandle>;
  public let focusEpochValid: Bool;
  public let focusEpoch: Uint32;
  public let cameraBaseline: ref<NCCFlightCameraWindow>;
  public let cameraActive: ref<NCCFlightCameraWindow>;
  public let cameraCurrent: ref<NCCFlightCameraWindow>;
  public let cameraActiveArmed: Bool;
  public let transitionTrace: ref<NCCFlightTransitionTrace>;
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

@addMethod(StateGameScriptInterface)
public final func NCCFlightWritePosition(position: Vector3) -> Bool {
  let player = this.owner as PlayerPuppet;
  let typedPosition: Vector3 = position;
  let value: Variant;
  if !IsDefined(player) {
    return false;
  }
  value = ToVariant(typedPosition);
  if !IsDefined(value) || NotEquals(VariantTypeName(value), n"Vector3") {
    return false;
  }
  // The original 2.5 setter rejects Position. Only the exact scoped native
  // bridge may issue a position-only write; true means issued, not observed.
  return this.SetStateVectorParameter(physicsStateValue.Position, value);
}

@addMethod(PlayerPuppet)
public final func NCCFlightInput() -> Uint32 {
  // Native exact-function result bridge replaces only this return value.
  // Default blocks movement and lacks READY, so a missing bridge fails closed.
  return 256u;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeInteractionFlags(scriptInterface: ref<StateGameScriptInterface>) -> Int32 {
  let board: ref<IBlackboard>;
  let workspots: ref<WorkspotGameSystem>;
  let flags = 0;
  if IsDefined(scriptInterface) {
    if scriptInterface.owner != this || scriptInterface.executionOwner != this { return -1; }
    board = scriptInterface.localBlackboard;
    workspots = scriptInterface.GetWorkspotSystem();
  } else {
    board = GameInstance.GetBlackboardSystem(this.GetGame()).GetLocalInstanced(this.GetEntityID(), GetAllBlackboardDefs().PlayerStateMachine);
    workspots = GameInstance.GetWorkspotSystem(this.GetGame());
  }
  if !IsDefined(board) || !IsDefined(workspots) { return -1; }
  if board.GetBool(GetAllBlackboardDefs().PlayerStateMachine.IsUIZoomDevice) { flags += 1; }
  if board.GetBool(GetAllBlackboardDefs().PlayerStateMachine.IsInteractingWithDevice) { flags += 2; }
  if board.GetInt(GetAllBlackboardDefs().PlayerStateMachine.IsInWorkspot) != 0 { flags += 4; }
  // Device workspot entry sets its blackboard after the native playback call.
  // This is the same native actor query used by WorkspotDecisions.EnterCondition.
  if workspots.IsActorInWorkspot(this) { flags += 8; }
  return flags;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeFinishInteractionYield() {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !probe.interactionYield || probe.arrivalUnconfirmed { return; }
  probe.restoreUnconfirmed = false;
  probe.stopRequested = false;
  probe.active = false;
  probe.paused = false;
  probe.interfaceRef = null;
  probe.status = "Flight stopped for device/workspot interaction; normal collision restored without relocation";
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeYieldInteraction(scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || probe.arrivalUnconfirmed { return false; }
  if !probe.interactionYield {
    probe.interactionYield = true;
    if probe.interactionFlags < 0 {
      probe.interactionReason = "Current interaction context is unavailable; flight cancels without relocation";
    } else {
      probe.interactionReason = "Device/workspot interaction owns player placement; flight will not relocate the player";
    }
    probe.interactionRestoreInterface = probe.interfaceRef;
    probe.interactionRestoreFilter = probe.baselineFilter;
    probe.interactionRestoreCapture = probe.captureWrites;
  }
  // This latch survives flags clearing and failed collision restoration.
  probe.requested = false;
  probe.preparePending = false;
  probe.prepared = false;
  probe.resumeRequested = false;
  probe.exitRequest = 0;
  probe.transitionPending = false;
  probe.positionReadbackPending = false;
  if !probe.active {
    probe.status = "Flight cancelled for device/workspot interaction; no relocation submitted";
    return !probe.restoreUnconfirmed;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || scriptInterface.executionOwner != this
    || probe.interfaceRef != scriptInterface || probe.interactionRestoreInterface != scriptInterface
    || probe.captureWrites != probe.interactionRestoreCapture || probe.capturedInterface != scriptInterface
    || !probe.capturedNormal || !this.NCCFlightProbeIsFilter(probe.interactionRestoreFilter) {
    probe.restoreUnconfirmed = true;
    probe.active = false;
    probe.interfaceRef = null;
    probe.status = "Interaction cleanup awaits a fresh normal filter; previous state is no longer owned; no relocation submitted";
    return false;
  }
  if this.NCCFlightProbeWriteFilter(scriptInterface, probe.interactionRestoreFilter) {
    this.NCCFlightProbeFinishInteractionYield();
    return true;
  }
  probe.restoreUnconfirmed = true;
  probe.paused = true;
  probe.stopRequested = true;
  probe.status = "Interaction cleanup will retry only its owned normal collision filter; no relocation submitted";
  return false;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeCheckInteraction(scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || probe.arrivalUnconfirmed { return false; }
  if probe.interactionYield {
    if probe.active {
      this.NCCFlightProbeYieldInteraction(scriptInterface);
      return true;
    }
    // Completed cleanup needs no polling or status changes. Existing idle and
    // read-only validation handling may run; only a new Start clears the latch.
    return false;
  }
  if !probe.active && !probe.requested && !probe.transitionPending { return false; }
  probe.interactionFlags = this.NCCFlightProbeInteractionFlags(scriptInterface);
  if probe.interactionFlags != 0 {
    this.NCCFlightProbeYieldInteraction(scriptInterface);
    return true;
  }
  return false;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeEnsureMenuListener() -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return false;
  }
  if IsDefined(probe.menuBlackboard) && IsDefined(probe.menuListener) {
    return true;
  }
  probe.menuBlackboard = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_System);
  if !IsDefined(probe.menuBlackboard) {
    return false;
  }
  probe.menuListener = probe.menuBlackboard.RegisterListenerBool(GetAllBlackboardDefs().UI_System.IsInMenu,
    this, n"NCCFlightProbeMenuChanged", true);
  if !IsDefined(probe.menuListener) {
    probe.menuBlackboard = null;
    return false;
  }
  probe.menuOpen = probe.menuBlackboard.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
  return true;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeRequestStop(reason: String) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && (probe.active || probe.requested || probe.transitionPending || probe.restoreUnconfirmed) {
    if !probe.stopRequested {
      probe.stopReason = reason;
    }
    probe.stopRequested = true;
    probe.requested = false;
    probe.preparePending = false;
    probe.prepared = false;
    probe.transitionPending = false;
    probe.transitionSerial += 1u;
  }
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbePause(reason: String) {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return;
  }
  if probe.arrivalUnconfirmed { return; }
  if probe.active || probe.transitionPending {
    probe.paused = true;
    probe.resumeRequested = false;
    probe.pauseReason = reason;
    probe.status = reason;
  } else {
    this.NCCFlightProbeRequestStop(reason + "; preparation cancelled");
  }
}

@addMethod(PlayerPuppet)
protected cb func NCCFlightProbeMenuChanged(value: Bool) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) {
    probe.menuOpen = value;
    if value {
      // Notifications only latch intent. Physics remains on owned updates.
      this.NCCFlightProbePause("Paused for game menu; choose Resume or Stop here");
    }
  }
  return true;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeObserveInput(packet: Uint32) {
  let probe = this.nccCollisionFlightProbe;
  let epoch: Uint32;
  let changed: Bool;
  probe.lastInputPacket = packet;
  probe.inputChecks = this.NCCFlightProbeCount(probe.inputChecks);
  if (packet & 512u) == 0u {
    this.NCCFlightProbePause("Paused: native input is unavailable");
    return;
  }
  epoch = packet / 65536u;
  changed = !probe.focusEpochValid || epoch != probe.focusEpoch;
  probe.focusEpoch = epoch;
  probe.focusEpochValid = (packet & 32768u) == 0u;
  if !probe.focusEpochValid {
    this.NCCFlightProbePause("Paused: focus cancellation counter exhausted; stop and restart the game");
  } else {
    if changed {
      this.NCCFlightProbePause("Paused after focus changed; choose Resume or Stop here");
    } else {
      if (packet & 4096u) != 0u {
        this.NCCFlightProbePause("Paused: game is not focused");
      }
    }
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeToggle() -> String {
  return "Use Start flight, Stop here, Resume, or Return to start explicitly";
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeStoredVector(value: Vector4) -> String {
  return FloatToStringPrec(value.X, 4) + "," + FloatToStringPrec(value.Y, 4) + "," + FloatToStringPrec(value.Z, 4);
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeStoredArrivalReport(message: String) -> String {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !probe.arrivalUnconfirmed || probe.arrivalOwner != this { return message; }
  // Command-time formatting of stored values only. No state lookup, physics,
  // input read, full Status recursion, or replay of the submitted relocation.
  return StrLeft(StrLeft(message, 256) + "\n[Stored relocation] serial=" + ToString(probe.arrivalSerial)
    + " cause=" + StrLeft(probe.arrivalReason, 256)
    + " lastOwnedState=" + StrLeft(NameToString(probe.arrivalRestoreMachine), 64) + "/" + StrLeft(NameToString(probe.arrivalRestoreState), 64)
    + " control=" + StrLeft(NameToString(probe.arrivalControl), 32)
    + " queuedExit=" + ToString(probe.arrivalExitIntent) + " processingExit=" + ToString(probe.arrivalProcessingExitIntent)
    + " paused/requested=" + ToString(probe.arrivalWasPaused) + "/" + ToString(probe.arrivalWasRequested)
    + " flags/menu=" + ToString(probe.arrivalInteractionFlags) + "/" + ToString(probe.arrivalMenuOpen)
    + " issuedAt=" + FloatToStringPrec(probe.arrivalIssuedAt, 4) + " capture=" + ToString(probe.arrivalRestoreCapture)
    + " submitted=" + this.NCCFlightProbeStoredVector(probe.arrivalSubmittedPosition)
    + " destination=" + this.NCCFlightProbeStoredVector(probe.arrivalDestination)
    + " origin=" + this.NCCFlightProbeStoredVector(probe.arrivalOriginDelta)
    + " priorTarget=" + this.NCCFlightProbeStoredVector(probe.arrivalPreviousTarget)
    + " priorReadbackPending/distance/originError=" + ToString(probe.arrivalPreviousReadbackPending)
      + "/" + FloatToStringPrec(probe.arrivalPreviousReadbackDistance, 4) + "/" + FloatToStringPrec(probe.arrivalPreviousOriginDivergence, 4)
    + " tolerance=" + FloatToStringPrec(probe.arrivalTolerance, 4)
    + " latestFailure=" + StrLeft(probe.arrivalFailureReason, 256)
    + " failureCallbacks/seconds=" + ToString(probe.arrivalFailureCallbacks) + "/" + FloatToStringPrec(probe.arrivalFailureElapsed, 4)
    + " lastValidObservation=" + ToString(probe.arrivalObservationValid) + "@" + FloatToStringPrec(probe.arrivalObservedAt, 4)
    + " observedState=" + StrLeft(NameToString(probe.arrivalObservedMachine), 64) + "/" + StrLeft(NameToString(probe.arrivalObservedState), 64)
    + " entity=" + this.NCCFlightProbeStoredVector(probe.arrivalObservedEntity)
    + " physics=" + this.NCCFlightProbeStoredVector(probe.arrivalObservedPhysics)
    + " distance=" + FloatToStringPrec(probe.arrivalDistance, 4)
    + " now[pending/active/restoreUnconfirmed/callbacks/seconds]=" + ToString(probe.arrivalPending)
      + "/" + ToString(probe.active) + "/" + ToString(probe.restoreUnconfirmed)
      + "/" + ToString(probe.arrivalCallbacks) + "/" + FloatToStringPrec(probe.arrivalElapsed, 4), 4096);
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbePrepare(commandPacket: Uint32) -> String {
  if !IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe = new NCCCollisionFlightProbeState();
  }
  let probe = this.nccCollisionFlightProbe;
  if probe.arrivalUnconfirmed {
    if probe.active || probe.restoreUnconfirmed {
      return this.NCCFlightProbeStoredArrivalReport("Start refused: queued relocation collision cleanup is not confirmed");
    }
    if probe.arrivalPending { return this.NCCFlightProbeStoredArrivalReport("Start refused: awaiting the queued relocation; no new request was submitted"); }
    if probe.arrivalOwner != this || !this.NCCFlightProbeEnsureMenuListener() || probe.menuOpen
      || (commandPacket & 512u) == 0u || (commandPacket & 4096u) != 0u || (commandPacket & 32768u) != 0u {
      return this.NCCFlightProbeStoredArrivalReport("Arrival recheck refused: close the menu and focus the game");
    }
    probe.arrivalPending = true;
    probe.arrivalCallbacks = 0;
    probe.arrivalElapsed = 0.0;
    probe.arrivalPollStartedAt = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame()));
    probe.status = "Read-only arrival recheck requested; after confirmation, press Start again";
    return this.NCCFlightProbeStoredArrivalReport(probe.status);
  }
  probe.interactionFlags = this.NCCFlightProbeInteractionFlags(null);
  if probe.interactionFlags < 0 {
    return "Start refused: current interaction state is unavailable";
  }
  if probe.interactionFlags > 0 {
    return "Start refused: finish the device or workspot interaction first";
  }
  if probe.active || probe.requested || probe.transitionPending {
    return "Flight already active or preparing; use Stop here, Resume, or Return to start";
  }
  if probe.restoreUnconfirmed {
    return "Flight refused: collision restoration is unconfirmed; crouch and stand to capture a fresh normal filter";
  }
  if !this.NCCFlightProbeEnsureMenuListener() {
    return "Flight refused: game-menu cancellation listener is unavailable";
  }
  if probe.menuOpen {
    return "Flight refused: close the game menu first";
  }
  if (commandPacket & 512u) == 0u || (commandPacket & 4096u) != 0u || (commandPacket & 32768u) != 0u {
    return "Flight refused: native input is unavailable, unfocused, or exhausted";
  }
  if probe.validationRequested {
    return "Flight refused: read-only validation is still pending";
  }
  if IsDefined(probe.cameraBaseline) && probe.cameraBaseline.running {
    return "Flight refused: close F1 and finish the 5-second camera baseline first";
  }
  // Each new explicit request owns its command-time cancellation generation.
  // The actual script input method must independently return READY with that
  // same generation on the natural engine callback before any physics write.
  probe.focusEpoch = commandPacket / 65536u;
  probe.lastAcceptedControl = n"start";
  probe.focusEpochValid = true;
  probe.stopRequested = false;
  probe.interactionYield = false;
  probe.interactionReason = "";
  probe.stopReason = "";
  probe.paused = false;
  probe.pauseReason = "";
  probe.resumeRequested = false;
  probe.exitRequest = 0;
  probe.lastClearValid = false;
  probe.clearanceClock = 0.0;
  probe.clearanceProbes = 0;
  probe.recoveryUsed = false;
  probe.clearanceFailed = false;
  probe.positionWritesIssued = 0;
  probe.positionReadbacks = 0;
  probe.positionRefusals = 0;
  probe.positionReadbackPending = false;
  probe.positionReadbackDistance = 0.0;
  probe.positionOriginDivergence = 0.0;
  probe.positionLastRefusal = "";
  probe.requested = true;
  probe.preparePending = true;
  probe.prepared = false;
  probe.prepareCallbacks = 0;
  probe.prepareElapsed = 0.0;
  probe.preparedInterface = null;
  probe.transitionTrace = new NCCFlightTransitionTrace();
  probe.transitionTrace.TraceInitialize();
  probe.status = "Requested: close F1 to prepare grounded locomotion";
  return probe.status;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeReturn() -> String {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && probe.arrivalUnconfirmed {
    return this.NCCFlightProbeStoredArrivalReport("Return refused: the previous relocation is unresolved; no additional request was submitted");
  }
  if IsDefined(probe) && probe.interactionYield {
    return "Return refused: flight yielded to an interaction; no relocation will be submitted";
  }
  if !IsDefined(probe) || (!probe.active && !probe.transitionPending) {
    return "Return refused: no active flight session";
  }
  probe.exitRequest = 2;
  probe.lastAcceptedControl = n"return";
  probe.resumeRequested = false;
  probe.paused = true;
  probe.status = "Requested: return to the activation point and restore collision";
  return probe.status;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeStopHere() -> String {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return "Flight is already stopped";
  }
  if probe.arrivalUnconfirmed {
    return this.NCCFlightProbeStoredArrivalReport("Flight movement is stopped; the queued relocation remains unresolved and cannot be cancelled here");
  }
  if !probe.active && !probe.transitionPending {
    probe.requested = false;
    probe.preparePending = false;
    probe.prepared = false;
    probe.status = "Flight stopped; preparation cancelled";
    return probe.status;
  }
  probe.exitRequest = 1;
  probe.lastAcceptedControl = n"stop-here";
  probe.resumeRequested = false;
  probe.paused = true;
  probe.status = "Requested: stop here if the player capsule is clear";
  return probe.status;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeResume(commandPacket: Uint32) -> String {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && probe.arrivalUnconfirmed {
    return this.NCCFlightProbeStoredArrivalReport("Resume refused: queued relocation arrival is unresolved; flight will not resume automatically");
  }
  if IsDefined(probe) && probe.interactionYield {
    return "Resume refused: finish the interaction and start a new flight";
  }
  if !IsDefined(probe) || !probe.active || !probe.paused || probe.transitionPending {
    return "Resume refused: flight is not paused in an owned state";
  }
  if probe.restoreUnconfirmed || probe.stopRequested || probe.exitRequest != 0 {
    return "Resume refused: finish collision cleanup or the pending exit first";
  }
  if !this.NCCFlightProbeEnsureMenuListener() || probe.menuBlackboard.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu) {
    return "Resume refused: close the game menu first";
  }
  if (commandPacket & 512u) == 0u || (commandPacket & 4096u) != 0u || (commandPacket & 32768u) != 0u {
    return "Resume refused: native input is unavailable, unfocused, or exhausted";
  }
  probe.focusEpoch = commandPacket / 65536u;
  probe.focusEpochValid = true;
  probe.resumeRequested = true;
  probe.lastAcceptedControl = n"resume";
  probe.status = "Resume requested: close F1 and release movement keys";
  return probe.status;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeValidate() -> String {
  if !IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe = new NCCCollisionFlightProbeState();
  }
  let probe = this.nccCollisionFlightProbe;
  if probe.active || probe.requested || probe.transitionPending || probe.arrivalUnconfirmed {
    return "Validation refused: first stop the flight probe";
  }
  if !this.NCCFlightProbeEnsureMenuListener() {
    return "Validation refused: game-menu cancellation listener is unavailable";
  }
  probe.validationRequested = true;
  probe.status = "Read-only validation queued for the next locomotion update";
  return probe.status;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeCameraTrace() -> String {
  if !IsDefined(this.nccCollisionFlightProbe) {
    this.nccCollisionFlightProbe = new NCCCollisionFlightProbeState();
  }
  let probe = this.nccCollisionFlightProbe;
  if probe.active || probe.requested || probe.transitionPending || probe.arrivalUnconfirmed {
    return "Camera recording refused: first stop the flight probe";
  }
  probe.cameraBaseline = new NCCFlightCameraWindow();
  probe.cameraBaseline.Initialize(32, 5.0);
  probe.cameraBaseline.running = true;
  probe.cameraActive = new NCCFlightCameraWindow();
  probe.cameraActive.Initialize(64, 10.0);
  probe.cameraActiveArmed = true;
  probe.cameraCurrent = null;
  return "Camera baseline armed: close F1, look left/right for 5 seconds, then start one flight probe and repeat; Status prints both recordings";
}

@addMethod(PlayerPuppet)
private final func NCCFlightCameraStartActive(scriptInterface: ref<StateGameScriptInterface>) {
  let probe = this.nccCollisionFlightProbe;
  if probe.cameraActiveArmed && IsDefined(probe.cameraBaseline) && !probe.cameraBaseline.running
    && probe.cameraBaseline.frames > 0 && IsDefined(probe.cameraActive) {
    probe.cameraActiveArmed = false;
    probe.cameraActive.ReadOrigin(this, scriptInterface);
    probe.cameraActive.running = true;
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightCameraStop() {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) {
    return;
  }
  if IsDefined(probe.cameraBaseline) {
    probe.cameraBaseline.running = false;
    probe.cameraBaseline.frameOpen = false;
  }
  if IsDefined(probe.cameraActive) {
    probe.cameraActive.running = false;
    probe.cameraActive.frameOpen = false;
  }
  probe.cameraActiveArmed = false;
  probe.cameraCurrent = null;
}

@addMethod(PlayerPuppet)
public final func NCCFlightCameraBefore(timeDelta: Float, scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  let window: ref<NCCFlightCameraWindow>;
  let packet: Uint32;
  if !IsDefined(probe) {
    return false;
  }
  probe.cameraCurrent = null;
  if !IsDefined(scriptInterface) || scriptInterface.owner != this {
    this.NCCFlightCameraStop();
    return false;
  }
  if IsDefined(probe.cameraBaseline) && probe.cameraBaseline.running {
    // The button is pressed with F1 open. Start/pause the read-only baseline
    // until gameplay actually receives input, without consuming its duration.
    packet = this.NCCFlightInput();
    if (packet & 512u) == 0u || (packet & 256u) != 0u
      || GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UI_System).GetBool(GetAllBlackboardDefs().UI_System.IsInMenu) {
      return false;
    }
    window = probe.cameraBaseline;
  } else {
    if IsDefined(probe.cameraActive) && probe.cameraActive.running {
      if !probe.active && !probe.requested && !probe.transitionPending {
        probe.cameraActive.running = false;
        return false;
      }
      window = probe.cameraActive;
      packet = this.NCCFlightInput();
    }
  }
  if !IsDefined(window) {
    return false;
  }
  if !window.originRead {
    window.ReadOrigin(this, scriptInterface);
  }
  window.dt = MaxF(timeDelta, 0.0);
  window.packet = packet;
  window.frameOpen = true;
  window.Capture(this, scriptInterface, 0);
  probe.cameraCurrent = window;
  return true;
}

@addMethod(PlayerPuppet)
public final func NCCFlightCameraPhase(scriptInterface: ref<StateGameScriptInterface>, phase: Int32) {
  let probe = this.nccCollisionFlightProbe;
  let window: ref<NCCFlightCameraWindow>;
  if !IsDefined(probe) {
    return;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this {
    this.NCCFlightCameraStop();
    return;
  }
  window = probe.cameraCurrent;
  if !IsDefined(window) || !window.frameOpen {
    return;
  }
  window.Capture(this, scriptInterface, phase);
  if phase == 2 {
    window.Finish();
    if window == probe.cameraActive && !probe.active && !probe.requested && !probe.transitionPending {
      window.running = false;
    }
    probe.cameraCurrent = null;
  }
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
private final func NCCFlightProbeBoundedVector(value: Vector4, limit: Float) -> Bool {
  // Ordered bounds also reject NaN and infinities without assuming an API.
  return value.X >= -limit && value.X <= limit && value.Y >= -limit && value.Y <= limit
    && value.Z >= -limit && value.Z <= limit && value.W >= -limit && value.W <= limit;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeCount(value: Int32) -> Int32 {
  if value < 2147483647 { return value + 1; }
  return value;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbePositionRefused(scriptInterface: ref<StateGameScriptInterface>, reason: String) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) {
    this.NCCFlightTraceSnapshot(scriptInterface, n"refusal");
    if IsDefined(probe.transitionTrace) { probe.transitionTrace.TraceFreeze(n"first-refusal"); }
    probe.positionRefusals = this.NCCFlightProbeCount(probe.positionRefusals);
    probe.positionLastRefusal = reason;
    this.NCCFlightProbeRestore(scriptInterface, reason, true);
  }
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
private final func NCCFlightProbeCameraFacing(scriptInterface: ref<StateGameScriptInterface>) -> EulerAngles {
  let facing = Quaternion.ToEulerAngles(this.GetWorldOrientation());
  // Follow live world-camera yaw instead of feeding the body's previous yaw
  // back into every teleport. Keep body pitch/roll separate from camera look.
  if IsDefined(scriptInterface) && scriptInterface.owner == this {
    facing.Yaw = Transform.GetYaw(scriptInterface.GetCameraWorldTransform());
  }
  return facing;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeCaptureFilter(scriptInterface: ref<StateGameScriptInterface>, value: Variant, normalPreset: Bool) {
  let probe: ref<NCCCollisionFlightProbeState>;
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || scriptInterface.executionOwner != this
    || !this.NCCFlightProbeIsFilter(value) {
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
  probe.capturedNormal = normalPreset;
  probe.capturedInterface = scriptInterface;
  probe.captureWrites = this.NCCFlightProbeCount(probe.captureWrites);
  if probe.arrivalUnconfirmed {
    // Only a successful ORIGINAL nonzero-preset write confirms current normal
    // collision. It cannot confirm that the separate queued move has arrived.
    if normalPreset {
      this.NCCFlightProbeFinishQueuedRestore();
    } else {
      // The new engine state owns this ZERO. Revoke our previous movement and
      // baseline-write authority without claiming normal collision or arrival.
      probe.active = false;
      probe.interfaceRef = null;
      probe.restoreUnconfirmed = true;
      this.NCCFlightProbeArrivalFailed("Original zero-preset state replaced queued cleanup ownership");
    }
    return;
  }
  if !probe.interactionYield && (probe.active || probe.requested || probe.transitionPending) {
    probe.interactionFlags = this.NCCFlightProbeInteractionFlags(scriptInterface);
    if probe.interactionFlags != 0 {
      probe.interactionYield = true;
      if probe.interactionFlags < 0 {
        probe.interactionReason = "Current interaction context unavailable during original filter capture; no flight relocation submitted";
      } else {
        probe.interactionReason = "Original interaction state took placement control; no flight relocation submitted";
      }
    }
  }
  if probe.interactionYield {
    probe.requested = false;
    probe.preparePending = false;
    probe.prepared = false;
    probe.transitionPending = false;
    probe.resumeRequested = false;
    probe.exitRequest = 0;
    probe.positionReadbackPending = false;
    probe.active = false;
    probe.interfaceRef = null;
    if normalPreset {
      this.NCCFlightProbeFinishInteractionYield();
    } else {
      probe.restoreUnconfirmed = true;
      probe.status = "Interaction engine state owns a zero collision preset; waiting for its next normal filter; no relocation submitted";
    }
    return;
  }
  // This callback is reached only after the scoped ORIGINAL engine setter
  // succeeded. Owned ZERO writes are excluded by both native and script guards.
  probe.restoreUnconfirmed = false;
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
  probe.capturedNormal = false;
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
  probe.inputChecks = this.NCCFlightProbeCount(probe.inputChecks);
  probe.focusEpochValid = (probe.lastInputPacket & 512u) != 0u && (probe.lastInputPacket & 32768u) == 0u;
  if probe.focusEpochValid {
    probe.focusEpoch = probe.lastInputPacket / 65536u;
  }
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
  let cameraReport: String;
  let transitionReport: String;
  if !IsDefined(probe) {
    return "Probe has not been requested";
  }
  // Formatting happens only in this manually requested status command.
  if IsDefined(probe.cameraBaseline) {
    cameraReport = probe.cameraBaseline.Report("baseline");
  }
  if IsDefined(probe.cameraActive) {
    cameraReport += probe.cameraActive.Report("active");
  }
  if IsDefined(probe.transitionTrace) { transitionReport = probe.transitionTrace.TraceReport(); }
  return probe.status + "; active=" + ToString(probe.active)
    + "; validationRequested=" + ToString(probe.validationRequested)
    + "; transitionPending=" + ToString(probe.transitionPending)
    + "; requested=" + ToString(probe.requested)
    + "; paused=" + ToString(probe.paused)
    + "; pauseReason=" + probe.pauseReason
    + "; resumeRequested=" + ToString(probe.resumeRequested)
    + "; exitRequest=" + ToString(probe.exitRequest)
    + "; lastClearValid=" + ToString(probe.lastClearValid)
    + "; checkpointQueries=" + ToString(probe.clearanceProbes)
    + "; recoveryUsed=" + ToString(probe.recoveryUsed)
    + "; interactionYield=" + ToString(probe.interactionYield)
    + "; interactionFlagsLastObserved=" + ToString(probe.interactionFlags)
    + "; interactionReason=" + probe.interactionReason
    + "; queuedRelocationReason=" + probe.arrivalReason
    + "; arrivalPending=" + ToString(probe.arrivalPending)
    + "; arrivalUnconfirmed=" + ToString(probe.arrivalUnconfirmed)
    + "; arrivalSerial=" + ToString(probe.arrivalSerial)
    + "; arrivalCallbacks=" + ToString(probe.arrivalCallbacks) + "/64"
    + "; arrivalElapsed=" + FloatToStringPrec(probe.arrivalElapsed, 4) + "/0.5"
    + "; arrivalDistance=" + FloatToStringPrec(probe.arrivalDistance, 4)
    + "; arrivalTolerance=" + FloatToStringPrec(probe.arrivalTolerance, 4)
    + "; arrivalDestination=" + FloatToStringPrec(probe.arrivalDestination.X, 4)
      + "," + FloatToStringPrec(probe.arrivalDestination.Y, 4) + "," + FloatToStringPrec(probe.arrivalDestination.Z, 4)
    + "; clearanceFailed=" + ToString(probe.clearanceFailed)
    + "; preparePending=" + ToString(probe.preparePending)
    + "; prepared=" + ToString(probe.prepared)
    + "; preparationCallbacks=" + ToString(probe.prepareCallbacks)
    + "; preparationUnblockedSeconds=" + FloatToStringPrec(probe.prepareElapsed, 3)
    + "; elapsedSeconds=" + FloatToStringPrec(probe.elapsed, 3)
    + "; no automatic duration or trip-radius limit"
    + "; ticks=" + ToString(probe.ticks)
    + "; lastInputPacket=" + ToString(probe.lastInputPacket)
    + "; inputChecks=" + ToString(probe.inputChecks)
    + "; captureWrites=" + ToString(probe.captureWrites)
    + "; filterWrites=" + ToString(probe.filterWrites)
    + "; velocityWrites=" + ToString(probe.velocityWrites)
    + "; positionWritesIssued=" + ToString(probe.positionWritesIssued)
    + "; positionReadbacks=" + ToString(probe.positionReadbacks)
    + "; positionReadbackPending=" + ToString(probe.positionReadbackPending)
    + "; positionReadbackDistance=" + FloatToStringPrec(probe.positionReadbackDistance, 4)
    + "; positionOriginDivergence=" + FloatToStringPrec(probe.positionOriginDivergence, 4)
    + "; maxPositionReadbackDistance=" + FloatToStringPrec(probe.maxPositionReadbackDistance, 4)
    + "; maxPositionOriginDivergence=" + FloatToStringPrec(probe.maxPositionOriginDivergence, 4)
    + "; maxObservedEntityRadiusMeters=" + FloatToStringPrec(probe.maxObservedEntityRadius, 3)
    + "; lastIssuedTargetRadiusMeters=" + FloatToStringPrec(probe.lastIssuedTargetRadius, 3)
    + "; positionRefusals=" + ToString(probe.positionRefusals)
    + "; positionLastRefusal=" + probe.positionLastRefusal
    + "; stopRequested=" + ToString(probe.stopRequested)
    + "; stopReason=" + probe.stopReason
    + "; restoreUnconfirmed=" + ToString(probe.restoreUnconfirmed)
    + "; menuListener=" + ToString(IsDefined(probe.menuBlackboard) && IsDefined(probe.menuListener))
    + "; menuOpen=" + ToString(probe.menuOpen)
    + "; focusEpoch=" + ToString(probe.focusEpoch)
    + "; focusEpochValid=" + ToString(probe.focusEpochValid)
    + "; filterType=" + NameToString(probe.filterType)
    + "; velocityType=" + NameToString(probe.velocityType)
    + "; state=" + NameToString(probe.stateName)
    + "; machine=" + NameToString(probe.machineName) + "; " + this.NCCFlightClearanceReport() + cameraReport + transitionReport;
}

@addMethod(PlayerPuppet)
private const final func NCCFlightTraceOwnsContext(scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  return IsDefined(probe) && IsDefined(scriptInterface) && scriptInterface.owner == this
    && ((probe.active && probe.interfaceRef == scriptInterface)
      || (!probe.active && probe.transitionPending && probe.capturedInterface == scriptInterface));
}

@addMethod(PlayerPuppet)
private final func NCCFlightTraceRecord(scriptInterface: ref<StateGameScriptInterface>, phase: CName,
  physics: Vector4, entity: Vector4, valid: Bool, typeName: CName) {
  let probe = this.nccCollisionFlightProbe;
  let trace: ref<NCCFlightTransitionTrace>;
  let sample: ref<NCCFlightTransitionSample>;
  if !IsDefined(probe) || !IsDefined(probe.transitionTrace) { return; }
  trace = probe.transitionTrace;
  sample = trace.TraceNext();
  if !IsDefined(sample) { return; }
  sample.owned = this.NCCFlightTraceOwnsContext(scriptInterface);
  sample.phase = phase;
  sample.time = trace.elapsed;
  if sample.owned { sample.time = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())); }
  sample.dt = trace.lastDelta;
  sample.callback = trace.callbacks;
  sample.serial = probe.transitionSerial;
  sample.fromState = trace.fromState;
  sample.fromMachine = trace.fromMachine;
  sample.toState = trace.toState;
  sample.toMachine = trace.toMachine;
  sample.physicsValid = valid;
  sample.physicsType = typeName;
  sample.physics = physics;
  sample.entity = entity;
  sample.target = probe.target;
  sample.expected = probe.positionLastTarget;
  sample.recovery = trace.recovery;
  sample.error = new Vector4(0.0, 0.0, 0.0, 0.0);
  if valid {
    sample.error = new Vector4(physics.X - sample.expected.X, physics.Y - sample.expected.Y, physics.Z - sample.expected.Z, 0.0);
  }
  sample.pending = probe.positionReadbackPending;
  sample.active = probe.active;
  sample.paused = probe.paused;
  sample.handoff = probe.transitionPending;
  sample.writes = probe.positionWritesIssued;
  sample.captures = probe.captureWrites;
  if !sample.owned { trace.TraceFreeze(n"owner-or-interface-changed"); }
}

@addMethod(PlayerPuppet)
public final func NCCFlightTraceSnapshot(scriptInterface: ref<StateGameScriptInterface>, phase: CName) {
  let probe = this.nccCollisionFlightProbe;
  let value: Variant;
  let physics: Vector4;
  let entity: Vector4;
  let valid: Bool;
  if !IsDefined(probe) || !IsDefined(probe.transitionTrace) || !probe.transitionTrace.TraceAvailable() { return; }
  if this.NCCFlightTraceOwnsContext(scriptInterface) {
    value = scriptInterface.GetStateVectorParameter(physicsStateValue.Position);
    entity = this.GetWorldPosition();
    valid = IsDefined(value) && Equals(VariantTypeName(value), n"Vector4");
    if valid { physics = FromVariant<Vector4>(value); }
  }
  this.NCCFlightTraceRecord(scriptInterface, phase, physics, entity, valid, VariantTypeName(value));
}

@addMethod(PlayerPuppet)
public final func NCCFlightTraceBefore(timeDelta: Float, scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !IsDefined(probe.transitionTrace) || !probe.transitionTrace.running { return false; }
  if !probe.active && !probe.transitionPending {
    probe.transitionTrace.TraceFreeze(n"session-ended");
    return false;
  }
  if !probe.transitionTrace.TraceAdvance(timeDelta) { return false; }
  if !this.NCCFlightTraceOwnsContext(scriptInterface) {
    this.NCCFlightTraceSnapshot(scriptInterface, n"invalid-update-owner");
    return false;
  }
  if probe.transitionTrace.watch > 0 { this.NCCFlightTraceSnapshot(scriptInterface, n"before-vanilla-update"); }
  return true;
}

@addMethod(PlayerPuppet)
public final func NCCFlightTraceAfter(scriptInterface: ref<StateGameScriptInterface>) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && IsDefined(probe.transitionTrace) && probe.transitionTrace.running && probe.transitionTrace.watch > 0 {
    this.NCCFlightTraceSnapshot(scriptInterface, n"after-vanilla-update");
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightTraceEndCallback() {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && IsDefined(probe.transitionTrace) && probe.transitionTrace.running && probe.transitionTrace.watch > 0 {
    probe.transitionTrace.watch -= 1;
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightTraceState(scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName, entering: Bool) {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !IsDefined(probe.transitionTrace) || !probe.transitionTrace.running { return; }
  if !probe.active && !probe.transitionPending { return; }
  if entering {
    probe.transitionTrace.toState = stateName;
    probe.transitionTrace.toMachine = machineName;
    this.NCCFlightTraceSnapshot(scriptInterface, n"fresh-filter-capture");
  } else {
    probe.transitionTrace.fromState = stateName;
    probe.transitionTrace.fromMachine = machineName;
    probe.transitionTrace.toState = n"None";
    probe.transitionTrace.toMachine = n"None";
    probe.transitionTrace.watch = 4;
    this.NCCFlightTraceSnapshot(scriptInterface, n"before-locomotion-exit");
  }
}

@addMethod(PlayerPuppet)
public const final func NCCFlightProbeOwnsMovement(const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  return IsDefined(probe) && probe.active && IsDefined(scriptInterface)
    && scriptInterface.owner == this && IsDefined(probe.interfaceRef)
    && probe.interfaceRef == scriptInterface;
}

@wrapMethod(LocomotionTransition)
protected const final func WantsToDodge(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if Equals(this.GetStateMachineName(), n"Locomotion") && IsDefined(scriptInterface) {
    let player = scriptInterface.owner as PlayerPuppet;
    if IsDefined(player) && player.NCCFlightProbeOwnsMovement(scriptInterface) {
      // Control is flight descent while this exact interface owns movement.
      // The original decision only checks eligibility and writes DodgeDirection;
      // its caller still performs normal action-listener/decision bookkeeping.
      return false;
    }
  }
  return wrappedMethod(stateContext, scriptInterface);
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeAllowed(stateName: CName, machineName: CName) -> Bool {
  return Equals(machineName, n"Locomotion")
    && (Equals(stateName, n"stand") || Equals(stateName, n"crouch")
      || Equals(stateName, n"preCrouch") || Equals(stateName, n"sprint")
      || Equals(stateName, n"sprintWindup") || Equals(stateName, n"fall")
      || Equals(stateName, n"jump") || Equals(stateName, n"aimWalk")
      || Equals(stateName, n"doubleJump") || Equals(stateName, n"chargeJump")
      || Equals(stateName, n"hoverJump") || Equals(stateName, n"regularLand"));
}

@wrapMethod(SprintDecisions)
protected const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if Equals(this.GetStateMachineName(), n"Locomotion") && IsDefined(scriptInterface) {
    let player = scriptInterface.owner as PlayerPuppet;
    if IsDefined(player) && player.NCCFlightProbeOwnsMovement(scriptInterface) { return false; }
  }
  return wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(CrouchDecisions)
protected const func ToSprint(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if Equals(this.GetStateMachineName(), n"Locomotion") && IsDefined(scriptInterface) {
    let player = scriptInterface.owner as PlayerPuppet;
    if IsDefined(player) && player.NCCFlightProbeOwnsMovement(scriptInterface) { return false; }
  }
  return wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(CrouchDecisions)
protected const func ToCrouchSprint(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if Equals(this.GetStateMachineName(), n"Locomotion") && IsDefined(scriptInterface) {
    let player = scriptInterface.owner as PlayerPuppet;
    if IsDefined(player) && player.NCCFlightProbeOwnsMovement(scriptInterface) { return false; }
  }
  return wrappedMethod(stateContext, scriptInterface);
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeObserveExitPosition(scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  let value: Variant;
  let physics: Vector4;
  let entity: Vector4;
  let divergence: Vector4;
  if !IsDefined(probe) || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || probe.interfaceRef != scriptInterface {
    return false;
  }
  value = scriptInterface.GetStateVectorParameter(physicsStateValue.Position);
  if !IsDefined(value) || NotEquals(VariantTypeName(value), n"Vector4") { return false; }
  physics = FromVariant<Vector4>(value);
  entity = this.GetWorldPosition();
  if !this.NCCFlightProbeBoundedVector(physics, 100000.0) || !this.NCCFlightProbeBoundedVector(entity, 100000.0)
    || AbsF(physics.W - 1.0) > 0.001 || AbsF(entity.W - 1.0) > 0.001 { return false; }
  divergence = new Vector4(physics.X - entity.X - probe.positionOriginDelta.X,
    physics.Y - entity.Y - probe.positionOriginDelta.Y, physics.Z - entity.Z - probe.positionOriginDelta.Z, 0.0);
  if !(Vector4.Length(divergence) <= 0.25)
    || (probe.positionReadbackPending && !(Vector4.Distance(physics, probe.positionLastTarget) <= 1.0)) {
    return false;
  }
  probe.exitObservedPosition = entity;
  return true;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeArrivalFailed(reason: String) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && probe.arrivalUnconfirmed {
    probe.arrivalPending = false;
    probe.arrivalFailureReason = reason;
    probe.arrivalFailureCallbacks = probe.arrivalCallbacks;
    probe.arrivalFailureElapsed = probe.arrivalElapsed;
    probe.status = reason + "; arrival unconfirmed; Start can request a read-only recheck after collision cleanup";
  }
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeFinishQueuedRestore() {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !probe.arrivalUnconfirmed || probe.arrivalOwner != this { return; }
  probe.restoreUnconfirmed = false;
  probe.stopRequested = false;
  probe.active = false;
  probe.paused = false;
  probe.requested = false;
  probe.preparePending = false;
  probe.prepared = false;
  probe.resumeRequested = false;
  probe.exitRequest = 0;
  probe.transitionPending = false;
  probe.positionReadbackPending = false;
  probe.restoreMoved = true;
  probe.interfaceRef = null;
  // Filter restoration and arrival are independent facts. Never promote the
  // queued destination to a movement target or resume flight here.
  if probe.arrivalPending {
    probe.status = probe.arrivalReason + "; normal collision restored; awaiting queued arrival";
  } else {
    probe.status = "Normal collision restored; queued arrival remains unconfirmed; Start can request a read-only recheck";
  }
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeRetryQueuedRestore(scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !probe.arrivalUnconfirmed || !probe.active { return false; }
  if probe.arrivalOwner != this || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || probe.interfaceRef != scriptInterface || probe.arrivalRestoreInterface != scriptInterface
    || probe.captureWrites != probe.arrivalRestoreCapture || probe.capturedInterface != scriptInterface
    || !probe.capturedNormal
    || !this.NCCFlightProbeIsFilter(probe.arrivalRestoreFilter) {
    probe.restoreUnconfirmed = true;
    this.NCCFlightProbeArrivalFailed("Queued relocation cleanup needs a fresh normal filter from the current owner");
    return false;
  }
  if this.NCCFlightProbeWriteFilter(scriptInterface, probe.arrivalRestoreFilter) {
    this.NCCFlightProbeFinishQueuedRestore();
    return true;
  }
  probe.restoreUnconfirmed = true;
  probe.paused = true;
  probe.stopRequested = true;
  probe.status = "Queued relocation submitted; retrying only its owned normal collision restore";
  return false;
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeArrivalTick(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName) {
  let probe = this.nccCollisionFlightProbe;
  let now: Float;
  let value: Variant;
  let physics: Vector4;
  let entity: Vector4;
  let expectedPhysics: Vector4;
  let divergence: Vector4;
  if !IsDefined(probe) || !probe.arrivalUnconfirmed { return; }
  // Cleanup may retry only the exact interface and immutable baseline that
  // owned submission. No teleport, ZERO, velocity or position write is retried.
  if probe.active {
    if !IsDefined(stateContext) || !stateContext.IsStateActive(probe.arrivalRestoreMachine, probe.arrivalRestoreState) {
      probe.restoreUnconfirmed = true;
      this.NCCFlightProbeArrivalFailed("Queued relocation cleanup refused: submitting locomotion state changed");
      return;
    }
    this.NCCFlightProbeRetryQueuedRestore(scriptInterface);
  }
  if !probe.arrivalPending { return; }
  probe.arrivalCallbacks += 1;
  if probe.arrivalOwner != this || !IsDefined(scriptInterface) || scriptInterface.owner != this {
    this.NCCFlightProbeArrivalFailed("Queued arrival observation refused: player owner changed");
    return;
  }
  now = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame()));
  if !(now >= probe.arrivalPollStartedAt && now >= probe.arrivalIssuedAt && now <= 1000000000.0)
    || !(timeDelta >= 0.0 && timeDelta <= 1.0) {
    this.NCCFlightProbeArrivalFailed("Queued arrival observation refused: invalid simulation time");
    return;
  }
  probe.arrivalElapsed = now - probe.arrivalPollStartedAt;
  if probe.arrivalCallbacks >= 64 || probe.arrivalElapsed >= 0.5 {
    this.NCCFlightProbeArrivalFailed("Queued arrival observation reached its 0.5-second or 64-callback limit");
    return;
  }
  if probe.active || probe.restoreUnconfirmed { return; }
  if !IsDefined(stateContext) || !stateContext.IsStateActive(machineName, stateName)
    || !this.NCCFlightProbeAllowed(stateName, machineName)
    || probe.capturedInterface != scriptInterface || !probe.capturedNormal
    || !this.NCCFlightProbeIsFilter(probe.capturedFilter)
    || this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive() {
    this.NCCFlightProbeArrivalFailed("Queued arrival observation refused: current normal locomotion context is not confirmed");
    return;
  }
  // Submission and same-frame observations cannot establish queued completion.
  if now <= probe.arrivalIssuedAt { return; }
  value = scriptInterface.GetStateVectorParameter(physicsStateValue.Position);
  if !IsDefined(value) || NotEquals(VariantTypeName(value), n"Vector4") {
    this.NCCFlightProbeArrivalFailed("Queued arrival observation refused: invalid physics position type");
    return;
  }
  physics = FromVariant<Vector4>(value);
  entity = this.GetWorldPosition();
  if !this.NCCFlightProbeBoundedVector(physics, 100000.0) || !this.NCCFlightProbeBoundedVector(entity, 100000.0)
    || AbsF(physics.W - 1.0) > 0.001 || AbsF(entity.W - 1.0) > 0.001 {
    this.NCCFlightProbeArrivalFailed("Queued arrival observation refused: invalid observed coordinates");
    return;
  }
  probe.arrivalObservationValid = true;
  probe.arrivalObservedAt = now;
  probe.arrivalObservedState = stateName;
  probe.arrivalObservedMachine = machineName;
  probe.arrivalObservedEntity = entity;
  probe.arrivalObservedPhysics = physics;
  divergence = new Vector4(physics.X - entity.X - probe.arrivalOriginDelta.X,
    physics.Y - entity.Y - probe.arrivalOriginDelta.Y, physics.Z - entity.Z - probe.arrivalOriginDelta.Z, 0.0);
  expectedPhysics = new Vector4(probe.arrivalDestination.X + probe.arrivalOriginDelta.X,
    probe.arrivalDestination.Y + probe.arrivalOriginDelta.Y, probe.arrivalDestination.Z + probe.arrivalOriginDelta.Z, 1.0);
  probe.arrivalDistance = Vector4.Distance(entity, probe.arrivalDestination);
  if !(Vector4.Length(divergence) <= 0.25)
    || !(probe.arrivalDistance <= probe.arrivalTolerance)
    || !(Vector4.Distance(physics, expectedPhysics) <= probe.arrivalTolerance) {
    return;
  }
  if !this.NCCFlightClearanceAt(scriptInterface, entity) { return; }
  probe.arrivalPending = false;
  probe.arrivalUnconfirmed = false;
  probe.target = entity;
  probe.status = "Queued relocation arrival observed with normal collision; press Start again for a new flight";
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeRestoreAt(scriptInterface: ref<StateGameScriptInterface>, destination: Vector4, facing: EulerAngles, move: Bool, reason: String) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  let zeroVelocity: Variant;
  let now: Float;
  let submittedPosition: Vector4;
  let submittedDistance: Float;
  if IsDefined(probe) && probe.arrivalUnconfirmed {
    return this.NCCFlightProbeRetryQueuedRestore(scriptInterface);
  }
  if this.NCCFlightProbeCheckInteraction(scriptInterface) {
    return !probe.active && !probe.restoreUnconfirmed;
  }
  if !IsDefined(probe) || !probe.active {
    return false;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || probe.interfaceRef != scriptInterface {
    probe.restoreUnconfirmed = true;
    probe.paused = true;
    probe.status = "Restore refused: owner changed";
    return false;
  }
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  if !this.NCCFlightProbeIsFilter(probe.baselineFilter) || !this.NCCFlightProbeIsVelocity(zeroVelocity) {
    probe.restoreUnconfirmed = true;
    probe.paused = true;
    probe.status = "Restore refused: invalid collision or velocity Variant; no physics writes";
    return false;
  }
  if move {
    now = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame()));
    if this.IsDead() || scriptInterface.IsMountedToObject() || !this.NCCFlightProbeBoundedVector(destination, 100000.0)
      || AbsF(destination.W - 1.0) > 0.001
      || !(facing.Yaw >= -100000.0 && facing.Yaw <= 100000.0)
      || !(facing.Pitch >= -100000.0 && facing.Pitch <= 100000.0)
      || !(facing.Roll >= -100000.0 && facing.Roll <= 100000.0)
      || !(now >= 0.0 && now <= 1000000000.0) {
      probe.status = "Restore refused: cannot move this player to a recovery position";
      return false;
    }
    submittedPosition = this.GetWorldPosition();
    submittedDistance = Vector4.Distance(submittedPosition, destination);
    if !this.NCCFlightProbeBoundedVector(submittedPosition, 100000.0)
      || AbsF(submittedPosition.W - 1.0) > 0.001 || !(submittedDistance > 0.00001 && submittedDistance <= 1000000.0) {
      // A zero-distance queued request has no observable arrival edge. Do not
      // submit one, even if the queue happens to process it synchronously.
      move = false;
      destination = submittedPosition;
      if submittedDistance >= 0.0 && submittedDistance <= 0.00001
        && this.NCCFlightProbeBoundedVector(submittedPosition, 100000.0)
        && AbsF(submittedPosition.W - 1.0) <= 0.001
        && this.NCCFlightProbeObserveExitPosition(scriptInterface)
        && this.NCCFlightClearanceAt(scriptInterface, probe.exitObservedPosition) {
        destination = probe.exitObservedPosition;
        reason += "; already at destination; no relocation submitted";
      } else {
        probe.clearanceFailed = true;
        reason += "; emergency cleanup without relocation: submission position is unconfirmed";
      }
    }
  }
  if move {
    // Record immutable submission before calling the native queue or restoring
    // collision. Even a rejected restore must never enqueue this move twice.
    probe.arrivalUnconfirmed = true;
    probe.arrivalPending = true;
    probe.arrivalOwner = this;
    probe.arrivalDestination = destination;
    probe.arrivalSubmittedPosition = submittedPosition;
    // The unchanged submission point must never satisfy arrival, including
    // requests shorter than the ordinary 25cm observation tolerance.
    probe.arrivalTolerance = MinF(0.25, submittedDistance * 0.25);
    probe.arrivalOriginDelta = probe.positionOriginDelta;
    probe.arrivalIssuedAt = now;
    probe.arrivalPollStartedAt = now;
    probe.arrivalElapsed = 0.0;
    probe.arrivalCallbacks = 0;
    probe.arrivalDistance = -1.0;
    probe.arrivalSerial = this.NCCFlightProbeCount(probe.arrivalSerial);
    probe.arrivalReason = reason;
    probe.arrivalControl = probe.lastAcceptedControl;
    probe.arrivalExitIntent = probe.exitRequest;
    probe.arrivalProcessingExitIntent = probe.processingExitRequest;
    probe.arrivalWasPaused = probe.paused;
    probe.arrivalWasRequested = probe.requested;
    probe.arrivalInteractionFlags = probe.interactionFlags;
    probe.arrivalMenuOpen = probe.menuOpen;
    probe.arrivalPreviousTarget = probe.positionLastTarget;
    probe.arrivalPreviousReadbackPending = probe.positionReadbackPending;
    probe.arrivalPreviousReadbackDistance = probe.positionReadbackDistance;
    probe.arrivalPreviousOriginDivergence = probe.positionOriginDivergence;
    probe.arrivalFailureReason = "";
    probe.arrivalFailureCallbacks = 0;
    probe.arrivalFailureElapsed = 0.0;
    probe.arrivalObservationValid = false;
    probe.arrivalObservedAt = 0.0;
    probe.arrivalObservedState = n"None";
    probe.arrivalObservedMachine = n"None";
    probe.arrivalObservedEntity = new Vector4(0.0, 0.0, 0.0, 0.0);
    probe.arrivalObservedPhysics = new Vector4(0.0, 0.0, 0.0, 0.0);
    probe.arrivalRestoreInterface = scriptInterface;
    probe.arrivalRestoreFilter = probe.baselineFilter;
    probe.arrivalRestoreCapture = probe.captureWrites;
    probe.arrivalRestoreState = probe.stateName;
    probe.arrivalRestoreMachine = probe.machineName;
    probe.requested = false;
    probe.preparePending = false;
    probe.prepared = false;
    probe.resumeRequested = false;
    probe.exitRequest = 0;
    probe.transitionPending = false;
    probe.positionReadbackPending = false;
    if IsDefined(probe.transitionTrace) && probe.transitionTrace.running {
      probe.transitionTrace.recovery = destination;
      probe.transitionTrace.watch = 4;
    }
    this.NCCFlightTraceSnapshot(scriptInterface, n"before-teleport");
    GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, destination, facing);
    this.NCCFlightTraceSnapshot(scriptInterface, n"after-teleport");
    scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity);
    return this.NCCFlightProbeRetryQueuedRestore(scriptInterface);
  }
  scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity);
  if this.NCCFlightProbeWriteFilter(scriptInterface, probe.baselineFilter) {
    probe.restoreUnconfirmed = false;
    probe.stopRequested = false;
    probe.active = false;
    probe.paused = false;
    probe.requested = false;
    probe.preparePending = false;
    probe.prepared = false;
    probe.resumeRequested = false;
    probe.exitRequest = 0;
    probe.transitionPending = false;
    probe.positionReadbackPending = false;
    probe.target = destination;
    probe.restoreMoved = move;
    probe.status = reason + "; filter restored";
    probe.interfaceRef = null;
    return true;
  } else {
    probe.restoreUnconfirmed = true;
    probe.paused = true;
    probe.stopRequested = true;
    probe.stopReason = reason;
    probe.status = "Restore failed: awaiting next locomotion update";
  }
  return false;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeRestore(scriptInterface: ref<StateGameScriptInterface>, reason: String, allowRecovery: Bool) {
  let probe = this.nccCollisionFlightProbe;
  let current: Vector4;
  let facing: EulerAngles;
  if !IsDefined(probe) {
    return;
  }
  if probe.arrivalUnconfirmed {
    this.NCCFlightProbeRetryQueuedRestore(scriptInterface);
    return;
  }
  if this.NCCFlightProbeCheckInteraction(scriptInterface) { return; }
  if !probe.active {
    probe.requested = false;
    probe.preparePending = false;
    probe.prepared = false;
    probe.transitionPending = false;
    probe.resumeRequested = false;
    probe.exitRequest = 0;
    probe.paused = false;
    if !probe.restoreUnconfirmed { probe.stopRequested = false; }
    probe.status = reason;
    return;
  }
  probe.paused = true;
  probe.resumeRequested = false;
  probe.restoreMoved = false;
  probe.clearanceFailed = false;
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || probe.interfaceRef != scriptInterface {
    probe.restoreUnconfirmed = true;
    probe.status = "Restore refused: current owned interface is unavailable";
    return;
  }
  current = this.GetWorldPosition();
  facing = Quaternion.ToEulerAngles(this.GetWorldOrientation());
  if this.NCCFlightProbeObserveExitPosition(scriptInterface)
    && this.NCCFlightClearanceAt(scriptInterface, probe.exitObservedPosition) {
    current = probe.exitObservedPosition;
    probe.clearanceFailed = false;
    probe.lastClearValid = true;
    probe.lastClearPosition = current;
    probe.lastClearFacing = facing;
    this.NCCFlightProbeRestoreAt(scriptInterface, current, facing, false, reason);
    return;
  }
  if !allowRecovery {
    probe.pauseReason = "Stop blocked: move into open space or choose Return to start";
    probe.status = probe.pauseReason;
    return;
  }
  if !this.IsDead() && !scriptInterface.IsMountedToObject() {
    if probe.lastClearValid && this.NCCFlightClearanceAt(scriptInterface, probe.lastClearPosition) {
      probe.recoveryUsed = true;
      this.NCCFlightProbeRestoreAt(scriptInterface, probe.lastClearPosition, probe.lastClearFacing, true,
        reason + "; recovery requested to the latest clear position");
      return;
    }
    if this.NCCFlightClearanceAt(scriptInterface, probe.start) {
      probe.recoveryUsed = true;
      this.NCCFlightProbeRestoreAt(scriptInterface, probe.start, probe.startFacing, true,
        reason + "; emergency recovery to the activation point");
      return;
    }
  }
  // An unavoidable engine exit must not leak ZERO into a state we do not own.
  // This emergency-only fallback is explicitly not a successful clear exit.
  probe.clearanceFailed = true;
  this.NCCFlightProbeRestoreAt(scriptInterface, current, facing, false,
    reason + "; emergency cleanup: clearance unconfirmed at current position");
}

@addMethod(PlayerPuppet)
private final func NCCFlightProbeProcessExit(scriptInterface: ref<StateGameScriptInterface>) {
  let probe = this.nccCollisionFlightProbe;
  let request: Int32;
  if !IsDefined(probe) || !probe.active || probe.exitRequest == 0 {
    return;
  }
  request = probe.exitRequest;
  probe.processingExitRequest = request;
  probe.exitRequest = 0;
  if request == 1 {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped here; normal gravity resumes", false);
  } else if request == 2 {
    if this.NCCFlightClearanceAt(scriptInterface, probe.start) {
      probe.clearanceFailed = false;
      this.NCCFlightProbeRestoreAt(scriptInterface, probe.start, probe.startFacing, true, "Return requested to the activation point");
    } else {
      probe.pauseReason = "Return blocked: activation point is no longer clear; choose Resume or Stop here";
      probe.status = probe.pauseReason;
    }
  }
  probe.processingExitRequest = 0;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeExpireTransition(expected: wref<NCCCollisionFlightProbeState>, serial: Uint32) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) && probe == expected && probe.transitionPending && probe.transitionSerial == serial {
    probe.transitionPending = false;
    probe.requested = false;
    probe.resumeRequested = false;
    probe.exitRequest = 0;
    probe.status = "Stopped with normal collision: no immediate supported state transition";
    probe.interfaceRef = null;
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeSuspendForTransition(scriptInterface: ref<StateGameScriptInterface>) {
  let probe = this.nccCollisionFlightProbe;
  let resume: Bool;
  let wasPaused: Bool;
  let exitIntent: Int32;
  let watchdog: ref<NCCCollisionFlightTransitionWatchdog>;
  if !IsDefined(probe) || !probe.active {
    return;
  }
  if this.NCCFlightProbeCheckInteraction(scriptInterface) { return; }
  resume = probe.requested;
  wasPaused = probe.paused;
  exitIntent = probe.exitRequest;
  probe.transitionFacing = this.NCCFlightProbeCameraFacing(scriptInterface);
  this.NCCFlightProbeRestore(scriptInterface, "Restored normal collision for locomotion exit", true);
  if !probe.active && resume && !probe.clearanceFailed && !probe.arrivalUnconfirmed && !probe.interactionYield {
    probe.requested = true;
    probe.paused = wasPaused || probe.restoreMoved;
    if probe.restoreMoved {
      probe.pauseReason = "Paused after recovery to a clear position; choose Resume or Stop here";
    }
    probe.exitRequest = exitIntent;
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
  if probe.arrivalUnconfirmed { return; }
  if this.NCCFlightProbeCheckInteraction(scriptInterface) { return; }
  // A bounded native scope captured the original state method's successful
  // filter write before this callback. The native getter cannot read it back.
  chosenFilter = probe.capturedFilter;
  zeroFilter = this.NCCFlightProbeZeroFilter();
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  if !capturedFresh || !IsDefined(probe.capturedInterface) || probe.capturedInterface != scriptInterface
    || !this.NCCFlightProbeIsFilter(chosenFilter) || !this.NCCFlightProbeIsFilter(zeroFilter)
    || !this.NCCFlightProbeIsVelocity(zeroVelocity) {
    // The prior exit already restored normal collision before handoff. An
    // unexpected in-place failure can clean up only through its owned context.
    if probe.active && probe.interfaceRef == scriptInterface {
      this.NCCFlightProbeRestore(scriptInterface, "Stopped: fresh collision capture failed", true);
      if probe.active {
        probe.restoreUnconfirmed = true;
        this.NCCFlightProbeRequestStop("Stopped: fresh capture and collision restoration failed; retrying owned cleanup");
        return;
      }
    }
    if probe.active {
      // No owned cleanup was possible through this unexpected interface.
      probe.restoreUnconfirmed = true;
    }
    probe.status = "Stopped: fresh collision capture failed; no flight reactivation";
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
  if !probe.paused || probe.resumeRequested {
    this.NCCFlightProbeObserveInput(this.NCCFlightInput());
  }
  if probe.menuOpen || !IsDefined(probe.menuBlackboard) || !IsDefined(probe.menuListener) {
    this.NCCFlightProbePause("Paused for game menu or unavailable menu listener");
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, true);
    return;
  }
  if !probe.requested || !this.NCCFlightProbeAllowed(stateName, machineName)
    || this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive()
    || (probe.transitionPending && EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())) > probe.transitionDeadline) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped for locomotion transition: "
      + NameToString(machineName) + "/" + NameToString(stateName), true);
    return;
  }
  if this.NCCFlightProbeWriteFilter(scriptInterface, zeroFilter) {
    resuming = probe.transitionPending;
    probe.transitionPending = false;
    probe.active = true;
    probe.filterWrites = this.NCCFlightProbeCount(probe.filterWrites);
    if resuming {
      // The exit destination is retained. No rewind-and-forward teleport.
      // A recovery teleport is checked against the next observed position.
      probe.positionLastTarget = probe.target + probe.positionOriginDelta;
      probe.positionLastTarget.W = 1.0;
      probe.positionReadbackPending = true;
    }
  } else {
    this.NCCFlightProbeRestore(scriptInterface, "Collision setter rejected state transition", true);
  }
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbePreparationTick(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName) -> Int32 {
  let probe = this.nccCollisionFlightProbe;
  let packet: Uint32;
  if !IsDefined(probe) || !probe.preparePending {
    return 0;
  }
  if !probe.requested || probe.active || probe.transitionPending {
    probe.preparePending = false;
    return 0;
  }
  probe.prepareCallbacks += 1;
  if probe.prepareCallbacks >= 4096 || !(timeDelta >= 0.0 && timeDelta <= 1.0) {
    this.NCCFlightProbeRestore(scriptInterface, "Preparation stopped: callback limit or invalid frame delta; start again", false);
    return 1;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || !IsDefined(stateContext)
    || probe.restoreUnconfirmed {
    this.NCCFlightProbeRestore(scriptInterface, "Preparation refused: owner or collision restoration is unconfirmed", false);
    return 1;
  }
  if this.NCCFlightProbeCheckInteraction(scriptInterface) { return 1; }
  packet = this.NCCFlightInput();
  this.NCCFlightProbeObserveInput(packet);
  if !IsDefined(probe.menuBlackboard) || !IsDefined(probe.menuListener) {
    this.NCCFlightProbeRequestStop("Preparation stopped: game-menu listener is unavailable");
  } else {
    probe.menuOpen = probe.menuBlackboard.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
    if probe.menuOpen {
      this.NCCFlightProbeRequestStop("Preparation stopped for game menu; start again after closing it");
    }
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, false);
    return 1;
  }
  if this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive() || NotEquals(machineName, n"Locomotion") {
    this.NCCFlightProbeRestore(scriptInterface, "Preparation stopped: unsupported player state", false);
    return 1;
  }
  if (packet & 256u) != 0u {
    probe.status = "Waiting for F1 to close before preparation";
    return 1;
  }
  probe.prepareElapsed += timeDelta;
  if probe.prepareElapsed >= 5.0 {
    this.NCCFlightProbeRestore(scriptInterface, "Preparation stopped: 5-second readiness limit; start again while grounded", false);
    return 1;
  }
  if !scriptInterface.IsOnGround() || !(Equals(stateName, n"stand") || Equals(stateName, n"crouch")) {
    probe.status = "Preparing: waiting for grounded stand/crouch";
    return 1;
  }
  if !stateContext.IsStateActive(machineName, stateName) {
    this.NCCFlightProbeRestore(scriptInterface, "Preparation refused: current normal collision state is not confirmed", false);
    return 1;
  }
  probe.prepareCaptureBefore = probe.captureWrites;
  probe.preparedInterface = scriptInterface;
  probe.preparedState = stateName;
  probe.preparedMachine = machineName;
  // Returning 2 authorizes exactly one ordinary current-state filter refresh.
  // The wrapper consumes this attempt before calling the original method.
  probe.preparePending = false;
  return 2;
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbePreparationComplete(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName, capsuleHeight: Float, capsuleRadius: Float) {
  let probe = this.nccCollisionFlightProbe;
  if !IsDefined(probe) || !probe.requested || probe.active || probe.transitionPending {
    return;
  }
  if probe.stopRequested || probe.restoreUnconfirmed || !IsDefined(scriptInterface)
    || scriptInterface.owner != this || probe.preparedInterface != scriptInterface
    || NotEquals(probe.preparedState, stateName) || NotEquals(probe.preparedMachine, machineName)
    || !IsDefined(stateContext) || !stateContext.IsStateActive(machineName, stateName)
    || probe.captureWrites == probe.prepareCaptureBefore || probe.capturedInterface != scriptInterface
    || !this.NCCFlightProbeIsFilter(probe.capturedFilter) {
    this.NCCFlightProbeRestore(scriptInterface, "Preparation refused: fresh current-state collision capture failed; start again", false);
    return;
  }
  probe.capsuleHeight = capsuleHeight;
  probe.capsuleRadius = capsuleRadius;
  probe.prepared = true;
  probe.status = "Prepared: normal collision captured; activation waits for the next owned update";
}

@addMethod(PlayerPuppet)
public final func NCCFlightProbeUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, stateName: CName, machineName: CName) {
  let probe = this.nccCollisionFlightProbe;
  let movement: Vector4;
  let cameraRight: Vector4;
  let cameraForward: Vector4;
  let step: Vector4;
  let nextTarget: Vector4;
  let physicsTarget: Vector4;
  let positionValue: Variant;
  let physicsPosition: Vector4;
  let entityPosition: Vector4;
  let originDelta: Vector4;
  let observedEntityRadius: Float;
  let targetRadius: Float;
  let speed: Float;
  let dt: Float;
  let packet: Uint32;
  let horizontal: Float;
  let forward: Float;
  let vertical: Float;
  let blocked: Bool;
  let speedPreset: Uint32;
  let zeroFilter: Variant;
  let zeroVelocity: Variant;
  if !IsDefined(probe) {
    return;
  }
  if probe.arrivalUnconfirmed {
    this.NCCFlightProbeArrivalTick(timeDelta, stateContext, scriptInterface, stateName, machineName);
    return;
  }
  if this.NCCFlightProbeCheckInteraction(scriptInterface) { return; }
  if probe.active && (!IsDefined(scriptInterface) || scriptInterface.owner != this
    || probe.interfaceRef != scriptInterface) {
    // Never apply an old state's baseline or ZERO through a different context.
    probe.restoreUnconfirmed = true;
    this.NCCFlightProbeRequestStop("Stopped: locomotion context changed; collision restoration is unconfirmed");
    probe.status = "Stopped: locomotion context changed; new state filter untouched";
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
    // A completed stop has no idle polling. An unconfirmed cleanup remains
    // blocked until an original filter capture establishes a safe new state.
    if probe.stopRequested && !probe.restoreUnconfirmed {
      probe.stopRequested = false;
      probe.status = probe.stopReason + "; inactive with normal collision confirmed";
    }
    return;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this {
    probe.requested = false;
    probe.positionRefusals = this.NCCFlightProbeCount(probe.positionRefusals);
    probe.positionLastRefusal = "Position refused: locomotion owner changed";
    probe.status = probe.positionLastRefusal;
    return;
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, true);
    return;
  }
  if !probe.active && !probe.transitionPending && (!probe.prepared || probe.preparePending
    || probe.preparedInterface != scriptInterface || NotEquals(probe.preparedState, stateName)
    || NotEquals(probe.preparedMachine, machineName) || !IsDefined(stateContext)
    || !stateContext.IsStateActive(machineName, stateName)) {
    this.NCCFlightProbeRestore(scriptInterface, "Activation refused: prepared locomotion state changed; start again", false);
    return;
  }
  if probe.transitionPending {
    this.NCCFlightProbeExpireTransition(probe, probe.transitionSerial);
    return;
  }
  probe.stateName = stateName;
  probe.machineName = machineName;
  packet = probe.lastInputPacket;
  if !probe.paused || probe.resumeRequested {
    packet = this.NCCFlightInput();
    this.NCCFlightProbeObserveInput(packet);
  }
  if !IsDefined(probe.menuBlackboard) || !IsDefined(probe.menuListener) {
    this.NCCFlightProbePause("Paused: game-menu cancellation listener is unavailable");
  } else {
    probe.menuOpen = probe.menuBlackboard.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
    if probe.menuOpen {
      this.NCCFlightProbePause("Paused for game menu; choose Resume or Stop here");
    }
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, true);
    return;
  }
  blocked = (packet & 256u) != 0u;
  if this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive() || !this.NCCFlightProbeAllowed(stateName, machineName) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped for unsupported player state: "
      + NameToString(machineName) + "/" + NameToString(stateName), true);
    return;
  }
  if !probe.requested {
    this.NCCFlightProbeRestore(scriptInterface, "Flight stopped", true);
    return;
  }
  if probe.active && probe.exitRequest != 0 {
    this.NCCFlightProbeProcessExit(scriptInterface);
    if !probe.active || probe.arrivalUnconfirmed { return; }
  }
  if probe.active && probe.resumeRequested && !blocked && !probe.menuOpen
    && (packet & 512u) != 0u && (packet & 4096u) == 0u && (packet & 32768u) == 0u
    && (packet & 255u) == 0u {
    probe.resumeRequested = false;
    probe.paused = false;
    probe.pauseReason = "";
  }
  blocked = blocked || probe.paused;
  if !probe.active && blocked {
    probe.status = "Waiting for F1 to close before activation";
    return;
  }
  if !(timeDelta >= 0.0 && timeDelta <= 1.0) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: invalid frame delta");
    return;
  }
  positionValue = scriptInterface.GetStateVectorParameter(physicsStateValue.Position);
  if !IsDefined(positionValue) || NotEquals(VariantTypeName(positionValue), n"Vector4") {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: physics Position is not a defined Vector4");
    return;
  }
  physicsPosition = FromVariant<Vector4>(positionValue);
  entityPosition = this.GetWorldPosition();
  if !this.NCCFlightProbeBoundedVector(physicsPosition, 100000.0)
    || !this.NCCFlightProbeBoundedVector(entityPosition, 100000.0)
    || AbsF(physicsPosition.W - 1.0) > 0.001 || AbsF(entityPosition.W - 1.0) > 0.001 {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: invalid or out-of-bounds current position");
    return;
  }
  originDelta = physicsPosition - entityPosition;
  originDelta.W = 0.0;
  if probe.active {
    observedEntityRadius = Vector4.Distance(entityPosition, probe.start);
    if observedEntityRadius >= 0.0 && observedEntityRadius <= 1000000.0 {
      probe.maxObservedEntityRadius = MaxF(probe.maxObservedEntityRadius, observedEntityRadius);
    }
    probe.positionOriginDivergence = Vector4.Length(originDelta - probe.positionOriginDelta);
    if probe.positionOriginDivergence >= 0.0 && probe.positionOriginDivergence <= 1000000.0 {
      probe.maxPositionOriginDivergence = MaxF(probe.maxPositionOriginDivergence, probe.positionOriginDivergence);
    }
    if !(probe.positionOriginDivergence <= 0.25) {
      this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: physics/entity origins diverged by more than 0.25m");
      return;
    }
    if probe.positionReadbackPending {
      probe.positionReadbackDistance = Vector4.Distance(physicsPosition, probe.positionLastTarget);
      if probe.positionReadbackDistance >= 0.0 && probe.positionReadbackDistance <= 1000000.0 {
        probe.maxPositionReadbackDistance = MaxF(probe.maxPositionReadbackDistance, probe.positionReadbackDistance);
      }
      if !(probe.positionReadbackDistance <= 1.0) {
        this.NCCFlightTraceRecord(scriptInterface, n"readback-failed", physicsPosition, entityPosition, true, n"Vector4");
        this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: prior target is more than 1m from physics readback");
        return;
      }
      if IsDefined(probe.transitionTrace) && probe.transitionTrace.running && probe.transitionTrace.watch > 0 {
        this.NCCFlightTraceRecord(scriptInterface, n"readback", physicsPosition, entityPosition, true, n"Vector4");
      }
      // This records a bounded next-callback observation, not exact arrival.
      probe.positionReadbacks = this.NCCFlightProbeCount(probe.positionReadbacks);
      probe.positionReadbackPending = false;
    }
  } else {
    if !(Vector4.Length(originDelta) <= 0.01) {
      this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: activation physics/entity origin delta exceeds 0.01m");
      return;
    }
    probe.positionOriginDelta = originDelta;
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
    probe.start = entityPosition;
    probe.target = probe.start;
    probe.startFacing = Quaternion.ToEulerAngles(this.GetWorldOrientation());
    if !this.NCCFlightClearanceInitialize(scriptInterface, entityPosition, probe.capsuleHeight, probe.capsuleRadius) {
      probe.requested = false;
      probe.status = "Activation refused: current capsule is not clear";
      return;
    }
    probe.lastClearPosition = entityPosition;
    probe.lastClearFacing = probe.startFacing;
    probe.lastClearValid = true;
    probe.lastClearanceProbePosition = entityPosition;
    probe.clearanceClock = 0.0;
    probe.elapsed = 0.0;
    probe.maxPositionReadbackDistance = 0.0;
    probe.maxPositionOriginDivergence = 0.0;
    probe.maxObservedEntityRadius = 0.0;
    probe.lastIssuedTargetRadius = 0.0;
    probe.ticks = 0;
    probe.filterWrites = 0;
    probe.velocityWrites = 0;
    probe.interfaceRef = scriptInterface;
    this.NCCFlightCameraStartActive(scriptInterface);
    if !this.NCCFlightProbeWriteFilter(scriptInterface, zeroFilter) {
      probe.requested = false;
      probe.status = "Collision setter rejected activation";
      return;
    }
    probe.active = true;
    if !this.NCCFlightClearanceVerifyControls(scriptInterface, this.GetWorldPosition()) {
      this.NCCFlightProbeRestore(scriptInterface, "Activation stopped: clearance controls failed under flight collision", true);
      return;
    }
    if IsDefined(probe.transitionTrace) && Equals(probe.transitionTrace.stop, n"awaiting-activation") {
      probe.transitionTrace.running = true;
      probe.transitionTrace.stop = n"running";
      probe.transitionTrace.lastDelta = timeDelta;
      probe.transitionTrace.fromState = stateName;
      probe.transitionTrace.fromMachine = machineName;
      probe.transitionTrace.toState = stateName;
      probe.transitionTrace.toMachine = machineName;
      this.NCCFlightTraceSnapshot(scriptInterface, n"activated");
    }
  }
  probe.elapsed = MinF(probe.elapsed + timeDelta, 1000000000.0);
  if !probe.paused {
    probe.clearanceClock = MinF(probe.clearanceClock + timeDelta, 0.25);
    if probe.clearanceClock >= 0.25 && Vector4.Distance(entityPosition, probe.lastClearanceProbePosition) >= 1.0 {
      probe.clearanceClock = 0.0;
      probe.lastClearanceProbePosition = entityPosition;
      probe.clearanceProbes = this.NCCFlightProbeCount(probe.clearanceProbes);
      if this.NCCFlightClearanceAt(scriptInterface, entityPosition) {
        probe.lastClearValid = true;
        probe.lastClearPosition = entityPosition;
        probe.lastClearFacing = Quaternion.ToEulerAngles(this.GetWorldOrientation());
      }
    }
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
  if !blocked {
    cameraRight = scriptInterface.GetCameraSystem().GetActiveCameraRight();
    cameraForward = scriptInterface.GetCameraSystem().GetActiveCameraForward();
  }
  if !this.NCCFlightProbeBoundedVector(cameraRight, 2.0) || !this.NCCFlightProbeBoundedVector(cameraForward, 2.0) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: invalid camera movement vectors");
    return;
  }
  movement = cameraRight * horizontal
    + cameraForward * forward
    + new Vector4(0.0, 0.0, vertical, 0.0);
  movement.W = 0.0;
  if !this.NCCFlightProbeBoundedVector(movement, 5.0) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: invalid movement vector");
    return;
  }
  if Vector4.Length(movement) > 1.0 {
    movement = Vector4.Normalize(movement);
  }
  speedPreset = (packet & 3072u) / 1024u;
  speed = 4.0;
  if speedPreset == 1u { speed = 2.0; }
  if speedPreset == 2u { speed = 6.0; }
  if speedPreset == 3u { speed = 8.0; }
  if (packet & 64u) != 0u { speed = 12.0; }
  if (packet & 128u) != 0u { speed = 0.75; }
  step = movement * (speed * dt);
  if !this.NCCFlightProbeBoundedVector(step, 0.60001) || !(Vector4.Length(step) <= 0.60001) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: movement step exceeds 0.6m");
    return;
  }
  nextTarget = probe.target + step;
  nextTarget.W = 1.0;
  physicsTarget = nextTarget + probe.positionOriginDelta;
  physicsTarget.W = 1.0;
  targetRadius = Vector4.Distance(nextTarget, probe.start);
  if !this.NCCFlightProbeBoundedVector(nextTarget, 100000.0)
    || !this.NCCFlightProbeBoundedVector(physicsTarget, 100000.0)
    || !(targetRadius >= 0.0 && targetRadius <= 1000000.0) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: target exceeds finite world-coordinate bounds");
    return;
  }
  if probe.interfaceRef != scriptInterface || scriptInterface.owner != this {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: current interface changed before write");
    return;
  }
  if !this.NCCFlightProbeIsFilter(probe.baselineFilter) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped: collision baseline became invalid", true);
    return;
  }
  if !this.NCCFlightProbeWriteFilter(scriptInterface, zeroFilter) {
    this.NCCFlightProbeRestore(scriptInterface, "Collision setter rejected update", true);
    return;
  }
  probe.filterWrites = this.NCCFlightProbeCount(probe.filterWrites);
  if !scriptInterface.NCCFlightWritePosition(new Vector3(physicsTarget.X, physicsTarget.Y, physicsTarget.Z)) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: guarded native bridge did not issue the write");
    return;
  }
  probe.target = nextTarget;
  probe.positionLastTarget = physicsTarget;
  probe.lastIssuedTargetRadius = targetRadius;
  probe.positionReadbackPending = true;
  probe.positionWritesIssued = this.NCCFlightProbeCount(probe.positionWritesIssued);
  if scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity) {
    probe.velocityWrites = this.NCCFlightProbeCount(probe.velocityWrites);
  } else {
    this.NCCFlightProbeRestore(scriptInterface, "Velocity setter rejected update", true);
    return;
  }
  probe.ticks = this.NCCFlightProbeCount(probe.ticks);
  if probe.paused {
    probe.status = probe.pauseReason;
  } else {
    probe.status = "Flight active; Stop here restores collision, Return to start is optional";
  }
}

@wrapMethod(LocomotionEventsTransition)
public func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
  let beforePlayer = scriptInterface.owner as PlayerPuppet;
  let cameraFrame: Bool;
  let traceFrame: Bool;
  let preparation: Int32;
  let stateName: CName;
  let machineName: CName;
  if IsDefined(beforePlayer) {
    cameraFrame = beforePlayer.NCCFlightCameraBefore(timeDelta, scriptInterface);
    traceFrame = beforePlayer.NCCFlightTraceBefore(timeDelta, scriptInterface);
  }
  wrappedMethod(timeDelta, stateContext, scriptInterface);
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(beforePlayer) && player != beforePlayer {
    beforePlayer.NCCFlightCameraStop();
    beforePlayer.NCCFlightTraceSnapshot(scriptInterface, n"owner-changed");
    cameraFrame = false;
    traceFrame = false;
  }
  if IsDefined(player) {
    stateName = this.GetStateName();
    machineName = this.GetStateMachineName();
    if cameraFrame {
      player.NCCFlightCameraPhase(scriptInterface, 1);
    }
    if traceFrame { player.NCCFlightTraceAfter(scriptInterface); }
    preparation = player.NCCFlightProbePreparationTick(timeDelta, stateContext, scriptInterface,
      stateName, machineName);
    if preparation == 2 {
      if this.GetStaticBoolParameterDefault("collisionFilterPresetIsZero", false) {
        player.NCCFlightProbeRestore(scriptInterface, "Preparation refused: current state requests a zero collision preset", false);
      } else {
        // This is the same configured state object used by vanilla OnEnter. The
        // normal method owns preset calculation and the existing scoped capture.
        this.SetCollisionFilter(scriptInterface);
        player.NCCFlightProbePreparationComplete(stateContext, scriptInterface, stateName, machineName,
          this.GetStaticFloatParameterDefault("capsuleHeight", 1.8), this.GetStaticFloatParameterDefault("capsuleRadius", 0.4));
      }
    } else if preparation == 0 {
      player.NCCFlightProbeUpdate(timeDelta, stateContext, scriptInterface, stateName, machineName);
    }
    if cameraFrame {
      player.NCCFlightCameraPhase(scriptInterface, 2);
    }
    if traceFrame { player.NCCFlightTraceEndCallback(); }
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
      player.NCCFlightProbeCaptureFilter(scriptInterface, capturedFilter,
        !this.GetStaticBoolParameterDefault("collisionFilterPresetIsZero", false));
      player.NCCFlightTraceState(scriptInterface, this.GetStateName(), this.GetStateMachineName(), true);
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
    player.NCCFlightTraceState(scriptInterface, this.GetStateName(), this.GetStateMachineName(), false);
    player.NCCFlightProbeSuspendForTransition(scriptInterface);
  }
  wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(LocomotionEventsTransition)
public func OnForcedExit(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(player) {
    player.NCCFlightTraceState(scriptInterface, this.GetStateName(), this.GetStateMachineName(), false);
    player.NCCFlightTraceSnapshot(scriptInterface, n"forced-exit");
    player.NCCFlightProbeRestore(scriptInterface, "Forced locomotion exit", true);
  }
  wrappedMethod(stateContext, scriptInterface);
}

@wrapMethod(PlayerPuppet)
protected cb func OnDetach() -> Bool {
  // No attempt to teleport or operate through an old interface during teardown.
  if IsDefined(this.nccCollisionFlightProbe) {
    if IsDefined(this.nccCollisionFlightProbe.menuBlackboard) && IsDefined(this.nccCollisionFlightProbe.menuListener) {
      this.nccCollisionFlightProbe.menuBlackboard.UnregisterListenerBool(GetAllBlackboardDefs().UI_System.IsInMenu,
        this.nccCollisionFlightProbe.menuListener);
    }
    this.nccCollisionFlightProbe.menuBlackboard = null;
    this.nccCollisionFlightProbe.menuListener = null;
    this.nccCollisionFlightProbe.transitionSerial += 1u;
    this.nccCollisionFlightProbe.capturedInterface = null;
    this.nccCollisionFlightProbe.interfaceRef = null;
  }
  this.nccCollisionFlightProbe = null;
  this.NCCFlightClearanceReset();
  return wrappedMethod();
}
