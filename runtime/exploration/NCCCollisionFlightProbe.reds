// Experimental 1.8 feasibility probe, installed only in the isolated test profile.
// No gravity changes. A 10-second limit and every normal stop return to start.
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
  public let positionWritesIssued: Int32;
  public let positionReadbacks: Int32;
  public let positionRefusals: Int32;
  public let positionReadbackPending: Bool;
  public let positionReadbackDistance: Float;
  public let positionOriginDivergence: Float;
  public let positionOriginDelta: Vector4;
  public let positionLastTarget: Vector4;
  public let positionLastRefusal: String;
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
    probe.transitionPending = false;
    probe.transitionSerial += 1u;
  }
}

@addMethod(PlayerPuppet)
protected cb func NCCFlightProbeMenuChanged(value: Bool) -> Bool {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) {
    probe.menuOpen = value;
    if value {
      // Blackboard notifications only cancel intent. The owned locomotion
      // callback performs restoration, including after a paused menu closes.
      this.NCCFlightProbeRequestStop("Stopped for game menu; start again after closing it");
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
  probe.inputChecks += 1;
  if (packet & 512u) == 0u {
    this.NCCFlightProbeRequestStop("Stopped: native input is unavailable");
    return;
  }
  epoch = packet / 65536u;
  changed = !probe.focusEpochValid || epoch != probe.focusEpoch;
  probe.focusEpoch = epoch;
  probe.focusEpochValid = (packet & 32768u) == 0u;
  if !probe.focusEpochValid {
    this.NCCFlightProbeRequestStop("Stopped: focus cancellation counter exhausted; restart the game");
  } else {
    if changed {
      this.NCCFlightProbeRequestStop("Stopped after focus changed; return to the game and start again");
    } else {
      if (packet & 4096u) != 0u {
        this.NCCFlightProbeRequestStop("Stopped: game is not focused; return and start again");
      }
    }
  }
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
  if probe.restoreUnconfirmed {
    return "Flight refused: collision restoration is unconfirmed; crouch and stand to capture a fresh normal filter";
  }
  if !this.NCCFlightProbeEnsureMenuListener() {
    return "Flight refused: game-menu cancellation listener is unavailable";
  }
  if probe.menuOpen {
    return "Flight refused: close the game menu first";
  }
  if !probe.focusEpochValid {
    return "Flight refused: validate native input before starting; restart if the focus counter is exhausted";
  }
  if probe.validationRequested {
    return "Flight refused: read-only validation is still pending";
  }
  if IsDefined(probe.cameraBaseline) && probe.cameraBaseline.running {
    return "Flight refused: close F1 and finish the 5-second camera baseline first";
  }
  if !IsDefined(probe.capturedInterface) || !this.NCCFlightProbeIsFilter(probe.capturedFilter) {
    return "Flight refused: no valid normal collision filter has been captured";
  }
  // The next ordinary update still verifies READY, current-interface identity,
  // grounded stand/crouch, and all setter Variants before enabling movement.
  probe.stopRequested = false;
  probe.stopReason = "";
  probe.positionWritesIssued = 0;
  probe.positionReadbacks = 0;
  probe.positionRefusals = 0;
  probe.positionReadbackPending = false;
  probe.positionReadbackDistance = 0.0;
  probe.positionOriginDivergence = 0.0;
  probe.positionLastRefusal = "";
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
  if probe.active || probe.requested || probe.transitionPending {
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
private final func NCCFlightProbePositionRefused(scriptInterface: ref<StateGameScriptInterface>, reason: String) {
  let probe = this.nccCollisionFlightProbe;
  if IsDefined(probe) {
    probe.positionRefusals += 1;
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
    + "; positionWritesIssued=" + ToString(probe.positionWritesIssued)
    + "; positionReadbacks=" + ToString(probe.positionReadbacks)
    + "; positionReadbackPending=" + ToString(probe.positionReadbackPending)
    + "; positionReadbackDistance=" + FloatToStringPrec(probe.positionReadbackDistance, 4)
    + "; positionOriginDivergence=" + FloatToStringPrec(probe.positionOriginDivergence, 4)
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
    + "; machine=" + NameToString(probe.machineName) + cameraReport;
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
  probe.positionReadbackPending = false;
  if !probe.active {
    // An ordinary exit has already returned to the safe start and restored
    // collision. Do not overwrite a new state's filter through an old context.
    probe.transitionPending = false;
    if !probe.restoreUnconfirmed {
      probe.stopRequested = false;
    }
    probe.status = reason;
    return;
  }
  if !IsDefined(scriptInterface) || scriptInterface.owner != this || probe.interfaceRef != scriptInterface {
    probe.restoreUnconfirmed = true;
    probe.status = "Restore refused: owner changed";
    return;
  }
  zeroVelocity = this.NCCFlightProbeZeroVelocity();
  if !this.NCCFlightProbeIsFilter(probe.baselineFilter) || !this.NCCFlightProbeIsVelocity(zeroVelocity) {
    probe.restoreUnconfirmed = true;
    probe.status = "Restore refused: invalid collision or velocity Variant; no physics writes";
    return;
  }
  if returnToStart && !this.IsDead() && !scriptInterface.IsMountedToObject() {
    GameInstance.GetTeleportationFacility(this.GetGame()).Teleport(this, probe.start, probe.startFacing);
  }
  scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity);
  if this.NCCFlightProbeWriteFilter(scriptInterface, probe.baselineFilter) {
    probe.restoreUnconfirmed = false;
    probe.stopRequested = false;
    probe.active = false;
    probe.transitionPending = false;
    probe.status = reason + "; filter restored";
    probe.interfaceRef = null;
  } else {
    probe.restoreUnconfirmed = true;
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
  probe.transitionFacing = this.NCCFlightProbeCameraFacing(scriptInterface);
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
    // A failed capture is not proof that the original filter write succeeded.
    // Never reapply ZERO or permit another activation until cleanup is known.
    if probe.active {
      probe.restoreUnconfirmed = true;
    }
    this.NCCFlightProbeRequestStop("Stopped: fresh collision capture failed; restoration may be unconfirmed");
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
  this.NCCFlightProbeObserveInput(this.NCCFlightInput());
  if probe.menuOpen || !IsDefined(probe.menuBlackboard) || !IsDefined(probe.menuListener) {
    this.NCCFlightProbeRequestStop("Stopped for game menu or unavailable menu listener");
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, true);
    return;
  }
  if !probe.requested || !this.NCCFlightProbeAllowed(stateName, machineName)
    || this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive()
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
  let cameraRight: Vector4;
  let cameraForward: Vector4;
  let step: Vector4;
  let nextTarget: Vector4;
  let physicsTarget: Vector4;
  let positionValue: Variant;
  let physicsPosition: Vector4;
  let entityPosition: Vector4;
  let originDelta: Vector4;
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
  if probe.active && (!IsDefined(scriptInterface) || scriptInterface.owner != this
    || probe.interfaceRef != scriptInterface) {
    // Never apply an old state's baseline or ZERO through a different context.
    // Only request the safe return when the current context still owns us.
    probe.restoreUnconfirmed = true;
    this.NCCFlightProbeRequestStop("Stopped: locomotion context changed; collision restoration is unconfirmed");
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
    probe.positionRefusals += 1;
    probe.positionLastRefusal = "Position refused: locomotion owner changed";
    probe.status = probe.positionLastRefusal;
    return;
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, true);
    return;
  }
  if probe.transitionPending {
    this.NCCFlightProbeExpireTransition(probe, probe.transitionSerial);
    return;
  }
  probe.stateName = stateName;
  probe.machineName = machineName;
  packet = this.NCCFlightInput();
  this.NCCFlightProbeObserveInput(packet);
  if !IsDefined(probe.menuBlackboard) || !IsDefined(probe.menuListener) {
    this.NCCFlightProbeRequestStop("Stopped: game-menu cancellation listener is unavailable");
  } else {
    probe.menuOpen = probe.menuBlackboard.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
    if probe.menuOpen {
      this.NCCFlightProbeRequestStop("Stopped for game menu; start again after closing it");
    }
  }
  if probe.stopRequested {
    this.NCCFlightProbeRestore(scriptInterface, probe.stopReason, true);
    return;
  }
  blocked = (packet & 256u) != 0u;
  if this.IsDead() || scriptInterface.IsMountedToObject() || scriptInterface.IsPlayerInBraindance()
    || scriptInterface.IsSceneAnimationActive() || !this.NCCFlightProbeAllowed(stateName, machineName) {
    this.NCCFlightProbeRestore(scriptInterface, "Stopped for unsupported player state", true);
    return;
  }
  if !probe.requested {
    this.NCCFlightProbeRestore(scriptInterface, "Returned to activation point", true);
    return;
  }
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
    probe.positionOriginDivergence = Vector4.Length(originDelta - probe.positionOriginDelta);
    if !(probe.positionOriginDivergence <= 0.25) {
      this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: physics/entity origins diverged by more than 0.25m");
      return;
    }
    if probe.positionReadbackPending {
      probe.positionReadbackDistance = Vector4.Distance(physicsPosition, probe.positionLastTarget);
      if !(probe.positionReadbackDistance <= 1.0) {
        this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: prior target is more than 1m from physics readback");
        return;
      }
      // This records a bounded next-callback observation, not exact arrival.
      probe.positionReadbacks += 1;
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
    probe.elapsed = 0.0;
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
  }
  probe.elapsed += timeDelta;
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
  cameraRight = scriptInterface.GetCameraSystem().GetActiveCameraRight();
  cameraForward = scriptInterface.GetCameraSystem().GetActiveCameraForward();
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
  if !this.NCCFlightProbeBoundedVector(nextTarget, 100000.0)
    || !this.NCCFlightProbeBoundedVector(physicsTarget, 100000.0)
    || !(Vector4.Distance(nextTarget, probe.start) <= 128.0) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: target exceeds the bounded probe area");
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
  probe.filterWrites += 1;
  if !scriptInterface.NCCFlightWritePosition(new Vector3(physicsTarget.X, physicsTarget.Y, physicsTarget.Z)) {
    this.NCCFlightProbePositionRefused(scriptInterface, "Position refused: guarded native bridge did not issue the write");
    return;
  }
  probe.target = nextTarget;
  probe.positionLastTarget = physicsTarget;
  probe.positionReadbackPending = true;
  probe.positionWritesIssued += 1;
  if scriptInterface.SetStateVectorParameter(physicsStateValue.LinearVelocity, zeroVelocity) {
    probe.velocityWrites += 1;
  } else {
    this.NCCFlightProbeRestore(scriptInterface, "Velocity setter rejected update", true);
    return;
  }
  probe.ticks += 1;
  probe.status = "Active position-only probe; native acceptance means issued, readback recorded separately";
}

@wrapMethod(LocomotionEventsTransition)
public func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) {
  let beforePlayer = scriptInterface.owner as PlayerPuppet;
  let cameraFrame: Bool;
  if IsDefined(beforePlayer) {
    cameraFrame = beforePlayer.NCCFlightCameraBefore(timeDelta, scriptInterface);
  }
  wrappedMethod(timeDelta, stateContext, scriptInterface);
  let player = scriptInterface.owner as PlayerPuppet;
  if IsDefined(beforePlayer) && player != beforePlayer {
    beforePlayer.NCCFlightCameraStop();
    cameraFrame = false;
  }
  if IsDefined(player) {
    if cameraFrame {
      player.NCCFlightCameraPhase(scriptInterface, 1);
    }
    player.NCCFlightProbeUpdate(timeDelta, stateContext, scriptInterface, this.GetStateName(), this.GetStateMachineName());
    if cameraFrame {
      player.NCCFlightCameraPhase(scriptInterface, 2);
    }
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
  return wrappedMethod();
}
