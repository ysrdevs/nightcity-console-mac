// Private 1.8 travel clearance probe. Queries only: no teleport, physics setter,
// gameplay event, or collision-filter mutation is performed by this file.
// LocomotionOverlapTest builds its own PlayerBlocker query mask on macOS 2.5;
// it does not read the player's currently active SimulationFilter.ZERO.
class NCCFlightClearanceState extends IScriptable {
  public let ready: Bool;
  public let height: Float;
  public let radius: Float;
  public let dimensions: Vector4;
  public let orientation: EulerAngles;
  public let queries: Int32;
  public let checks: Int32;
  public let blocked: Int32;
  public let rejected: Int32;
  public let clearControl: Bool;
  public let loweredControl: Bool;
  public let zeroControlsVerified: Bool;
  public let controlPasses: Int32;
  public let controlFeet: Vector4;
  public let lastFeet: Vector4;
  public let reason: String;
}

@addField(PlayerPuppet)
private let nccFlightClearance: ref<NCCFlightClearanceState>;

@addMethod(PlayerPuppet)
private final func NCCFlightClearanceFinite(value: Float) -> Bool {
  return value == value && AbsF(value) <= 1000000.0;
}

@addMethod(PlayerPuppet)
private final func NCCFlightClearanceFinitePosition(value: Vector4) -> Bool {
  return this.NCCFlightClearanceFinite(value.X) && this.NCCFlightClearanceFinite(value.Y)
    && this.NCCFlightClearanceFinite(value.Z) && this.NCCFlightClearanceFinite(value.W);
}

@addMethod(PlayerPuppet)
public final func NCCFlightClearanceReset() {
  let state = this.nccFlightClearance;
  if IsDefined(state) {
    state.ready = false;
    state.clearControl = false;
    state.loweredControl = false;
    state.zeroControlsVerified = false;
    state.reason = "Clearance needs a new grounded initialization";
  }
}

// Return 0 for no overlap, 1 for a valid overlap, 2 for rejected/inconsistent
// query inputs. A no-hit result does not establish world-streaming completeness.
@addMethod(PlayerPuppet)
private final func NCCFlightClearanceOverlap(scriptInterface: ref<StateGameScriptInterface>, feet: Vector4) -> Int32 {
  let result: TraceResult;
  let center: Vector4;
  let hit: Bool;
  let validHit: Bool;
  let state = this.nccFlightClearance;
  if !IsDefined(state) || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || !this.NCCFlightClearanceFinitePosition(feet) {
    return 2;
  }
  // Vanilla ClimbEvents uses (radius, height/2-radius, -1) with Roll=90.
  // Owner/physics position is the feet origin. Lift the envelope by 3 cm to
  // avoid treating ordinary supporting-floor contact as penetration.
  center = feet;
  center.Z += state.height * 0.5 + 0.03;
  if !this.NCCFlightClearanceFinitePosition(center) {
    return 2;
  }
  if state.queries < 2147483647 {
    state.queries += 1;
  }
  hit = scriptInterface.LocomotionOverlapTest(state.dimensions, center, state.orientation, result);
  validHit = TraceResult.IsValid(result);
  if (hit && !validHit) || (!hit && validHit) {
    return 2;
  }
  if hit {
    return 1;
  }
  return 0;
}

// Invoke once per accepted preparation, from the currently owned grounded
// locomotion callback, after its normal filter has been captured. The caller
// supplies the actual transition's capsuleHeight/capsuleRadius parameters.
@addMethod(PlayerPuppet)
public final func NCCFlightClearanceInitialize(scriptInterface: ref<StateGameScriptInterface>, observedFeet: Vector4,
  capsuleHeight: Float, capsuleRadius: Float) -> Bool {
  let lowered: Vector4;
  let query: Int32;
  let state = this.nccFlightClearance;
  if !IsDefined(state) {
    state = new NCCFlightClearanceState();
    this.nccFlightClearance = state;
  }
  this.NCCFlightClearanceReset();
  if !IsDefined(scriptInterface) || scriptInterface.owner != this
    || !this.NCCFlightClearanceFinitePosition(observedFeet)
    || !this.NCCFlightClearanceFinite(capsuleHeight) || !this.NCCFlightClearanceFinite(capsuleRadius)
    || capsuleRadius < 0.1 || capsuleRadius > 1.0 || capsuleHeight < capsuleRadius * 2.0 || capsuleHeight > 4.0 {
    state.reason = "Clearance initialization rejected the owner, position, or capsule dimensions";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  if !scriptInterface.IsOnGround() {
    state.reason = "Clearance initialization requires grounded locomotion";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  // Standing defaults are 1.8 m / 0.4 m in vanilla LocomotionEventsTransition.
  // Never shrink the query to a crouching profile or a smaller custom capsule.
  state.height = MaxF(capsuleHeight, 1.8);
  state.radius = MaxF(capsuleRadius, 0.4);
  state.dimensions = new Vector4(state.radius, state.height * 0.5 - state.radius, -1.0, 0.0);
  state.orientation.Roll = 90.0;
  state.orientation.Pitch = 0.0;
  state.orientation.Yaw = 0.0;
  state.lastFeet = observedFeet;
  query = this.NCCFlightClearanceOverlap(scriptInterface, observedFeet);
  if query != 0 {
    state.reason = "The standing clearance control is blocked or unavailable; move to open ground";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  state.clearControl = true;
  lowered = observedFeet;
  lowered.Z -= state.radius + 0.03;
  query = this.NCCFlightClearanceOverlap(scriptInterface, lowered);
  if query != 1 {
    state.reason = "The lowered capsule control found no valid collision; flight remains disabled";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  state.loweredControl = true;
  state.controlFeet = observedFeet;
  if state.controlPasses < 2147483647 { state.controlPasses += 1; }
  state.ready = true;
  state.reason = "Grounded clearance controls passed";
  return true;
}

// Repeat both controls immediately after the owned ZERO write, before the
// first position write. Do not use IsOnGround here: changing simulation filters
// may invalidate that contact flag. The verified original feet must be intact.
@addMethod(PlayerPuppet)
public final func NCCFlightClearanceVerifyControls(scriptInterface: ref<StateGameScriptInterface>, observedFeet: Vector4) -> Bool {
  let lowered: Vector4;
  let query: Int32;
  let delta: Vector4;
  let state = this.nccFlightClearance;
  if !IsDefined(state) {
    return false;
  }
  state.zeroControlsVerified = false;
  if !state.ready || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || !this.NCCFlightClearanceFinitePosition(observedFeet) {
    state.ready = false;
    state.reason = "ZERO clearance controls require the initialized owner and position";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  delta = observedFeet - state.controlFeet;
  delta.W = 0.0;
  if Vector4.LengthSquared(delta) > 0.0001 {
    state.ready = false;
    state.reason = "Player moved before ZERO clearance controls could be verified";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  state.ready = false;
  state.lastFeet = observedFeet;
  query = this.NCCFlightClearanceOverlap(scriptInterface, observedFeet);
  if query != 0 {
    state.reason = "Clear standing control failed after ZERO; no travel movement is allowed";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  lowered = observedFeet;
  lowered.Z -= state.radius + 0.03;
  query = this.NCCFlightClearanceOverlap(scriptInterface, lowered);
  if query != 1 {
    state.reason = "Lowered collision control failed after ZERO; no travel movement is allowed";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  state.zeroControlsVerified = true;
  if state.controlPasses < 2147483647 { state.controlPasses += 1; }
  state.ready = true;
  state.reason = "Clear and lowered controls passed with the flight filter active";
  return true;
}

// The owner must still match, but the interface may be a fresh locomotion
// context. The canonical query uses that context's own actor-exclusion list.
// A clear capsule in mid-air is allowed: ordinary gravity resumes on exit.
@addMethod(PlayerPuppet)
public final func NCCFlightClearanceAt(scriptInterface: ref<StateGameScriptInterface>, observedFeet: Vector4) -> Bool {
  let query: Int32;
  let state = this.nccFlightClearance;
  if !IsDefined(state) {
    return false;
  }
  if state.checks < 2147483647 { state.checks += 1; }
  if !state.ready || !IsDefined(scriptInterface) || scriptInterface.owner != this
    || !this.NCCFlightClearanceFinitePosition(observedFeet) {
    state.reason = "Clearance is not initialized or its owner/position is unavailable";
    if state.rejected < 2147483647 { state.rejected += 1; }
    return false;
  }
  state.lastFeet = observedFeet;
  query = this.NCCFlightClearanceOverlap(scriptInterface, observedFeet);
  if query != 0 {
    if query == 1 {
      state.reason = "Standing space is occupied; move into open space or choose Return to start";
      if state.blocked < 2147483647 { state.blocked += 1; }
    } else {
      state.reason = "Clearance query was rejected or inconsistent";
      if state.rejected < 2147483647 { state.rejected += 1; }
    }
    return false;
  }
  state.reason = "Standing capsule is clear of queried player blockers";
  return true;
}

@addMethod(PlayerPuppet)
public final func NCCFlightClearanceReport() -> String {
  let state = this.nccFlightClearance;
  if !IsDefined(state) {
    return "Clearance: not initialized";
  }
  return "Clearance: " + state.reason + " ready=" + ToString(state.ready)
    + " controls[clear,lowered]=" + ToString(state.clearControl) + "," + ToString(state.loweredControl)
    + " zeroControls=" + ToString(state.zeroControlsVerified) + " controlPasses=" + ToString(state.controlPasses)
    + " height=" + FloatToStringPrec(state.height, 3) + " radius=" + FloatToStringPrec(state.radius, 3)
    + " checks=" + ToString(state.checks) + " queries=" + ToString(state.queries)
    + " blocked=" + ToString(state.blocked) + " rejected=" + ToString(state.rejected)
    + " feet=" + FloatToStringPrec(state.lastFeet.X, 3) + "," + FloatToStringPrec(state.lastFeet.Y, 3)
    + "," + FloatToStringPrec(state.lastFeet.Z, 3);
}
