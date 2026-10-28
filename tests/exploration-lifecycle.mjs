import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Execute actual method bodies. Only syntax and explicit vector operations are
// adapted; engine calls are mocked and all lifecycle control flow is preserved.
const source=fs.readFileSync(new URL('../runtime/exploration/NCCCollisionFlightProbe.reds',import.meta.url),'utf8');
function body(name) {
  const start=source.indexOf(`func ${name}(`); assert(start>=0,name);
  const open=source.indexOf('{',start); let depth=1,end=open+1;
  for(;depth&&end<source.length;end++){if(source[end]==='{')depth++;if(source[end]==='}')depth--;}
  assert.equal(depth,0);
  return source.slice(open+1,end-1).replace(/\/\/[^\n]*/g,'')
    .replace(/let (\w+): Vector4;/g,'let $1 = new Vector4();').replace(/let (\w+): Float;/g,'let $1 = 0;')
    .replace(/let (\w+): Bool;/g,'let $1 = false;')
    .replace(/let (\w+): [^;]+;/g,'let $1;').replace(/([\w.]+) \/ (\d+)u/g,'Math.floor($1 / $2)')
    .replace(/\b(\d+)u\b/g,'$1').replace(/(?<![\w\\])n"/g,'"').replace(/scriptInterface.owner as PlayerPuppet/g,'AsPlayer(scriptInterface.owner)')
    .replace(/FromVariant<Vector4>/g,'FromVariant')
    .replaceAll('probe.target + probe.positionOriginDelta','Vector4.Add(probe.target,probe.positionOriginDelta)')
    .replaceAll('physicsPosition - entityPosition','Vector4.Sub(physicsPosition,entityPosition)')
    .replaceAll('originDelta - probe.positionOriginDelta','Vector4.Sub(originDelta,probe.positionOriginDelta)')
    .replace(/cameraRight \* horizontal\s*\+ cameraForward \* forward\s*\+ new Vector4\(0.0, 0.0, vertical, 0.0\)/g,
      'Vector4.Add(Vector4.Add(Vector4.Scale(cameraRight,horizontal),Vector4.Scale(cameraForward,forward)),new Vector4(0,0,vertical,0))')
    .replaceAll('movement * (speed * dt)','Vector4.Scale(movement,speed*dt)')
    .replaceAll('probe.target + step','Vector4.Add(probe.target,step)')
    .replaceAll('nextTarget + probe.positionOriginDelta','Vector4.Add(nextTarget,probe.positionOriginDelta)')
    .replace(/\bif\s+([^{}]+)\{/g,'if ($1) {')
    .replace(/\bwhile\s+([^{}]+)\{/g,'while ($1) {');
}
class Vector4 {
  constructor(X=0,Y=0,Z=0,W=0){Object.assign(this,{X,Y,Z,W});}
  static Add(a,b){return new Vector4(a.X+b.X,a.Y+b.Y,a.Z+b.Z,a.W+b.W);}
  static Sub(a,b){return new Vector4(a.X-b.X,a.Y-b.Y,a.Z-b.Z,a.W-b.W);}
  static Scale(a,n){return new Vector4(a.X*n,a.Y*n,a.Z*n,a.W*n);}
  static Length(a){return Math.hypot(a.X,a.Y,a.Z,a.W);}
  static Distance(a,b){return this.Length(this.Sub(a,b));}
  static Normalize(a){return this.Scale(a,1/this.Length(a));}
}
class Vector3{constructor(X,Y,Z){Object.assign(this,{X,Y,Z});}}
const methods={EnsureMenuListener:'',RequestStop:'reason',Pause:'reason',MenuChanged:'value',ObserveInput:'packet',
  StoredVector:'value',StoredArrivalReport:'message',
  InteractionFlags:'scriptInterface',FinishInteractionYield:'',YieldInteraction:'scriptInterface',CheckInteraction:'scriptInterface',
  Count:'value',BoundedVector:'value,limit',Allowed:'stateName,machineName',OwnsMovement:'scriptInterface',Toggle:'',Prepare:'commandPacket',Return:'',
  StopHere:'',Resume:'commandPacket',Restore:'scriptInterface,reason,allowRecovery',
  RestoreAt:'scriptInterface,destination,facing,move,reason',ObserveExitPosition:'scriptInterface',ProcessExit:'scriptInterface',
  PositionRefused:'scriptInterface,reason',CaptureFilter:'scriptInterface,value,normalPreset',SuspendForTransition:'scriptInterface',
  ArrivalFailed:'reason',FinishQueuedRestore:'',RetryQueuedRestore:'scriptInterface',
  ArrivalTick:'timeDelta,stateContext,scriptInterface,stateName,machineName',
  ExpireTransition:'expected,serial',ObserveStateFilter:'scriptInterface,stateName,machineName,capturedFresh',
  PreparationTick:'timeDelta,stateContext,scriptInterface,stateName,machineName',
  PreparationComplete:'stateContext,scriptInterface,stateName,machineName,capsuleHeight,capsuleRadius',
  Update:'timeDelta,stateContext,scriptInterface,stateName,machineName'};
const packet=(epoch=3,flags=512)=>epoch*65536+flags;
function fixture(){
  const s={menu:false,current:true,grounded:true,packet:packet(),time:100,entity:new Vector4(10,20,30,1),physics:new Vector4(10,20,30,1),
    interactionReads:0,workspotReads:0,zoom:false,device:false,workspotBB:0,workspot:false,
    reads:0,positionReads:0,entityReads:0,sampleAllocations:0,formats:0,normal:0,zero:0,restores:0,restoreArgs:[],velocity:0,positions:0,teleports:[],queries:[],callbacks:[],accepted:true,controls:true};
  const facing={Yaw:0,Pitch:0,Roll:0};
  const defaults=()=>({active:false,requested:false,paused:false,resumeRequested:false,exitRequest:0,preparePending:false,prepared:false,
    prepareCallbacks:0,prepareElapsed:0,transitionPending:false,transitionSerial:4,stopRequested:false,stopReason:'',restoreUnconfirmed:false,processingExitRequest:0,
    focusEpochValid:true,focusEpoch:3,lastInputPacket:packet(),inputChecks:0,captureWrites:0,baselineFilter:{valid:true},capturedFilter:{valid:true},capturedNormal:true,
    arrivalUnconfirmed:false,arrivalPending:false,arrivalSerial:0,arrivalElapsed:0,arrivalCallbacks:0,stateName:'stand',machineName:'Locomotion',
    ownFilterWrite:false,start:new Vector4(0,0,0,1),startFacing:facing,target:s.entity,lastClearValid:true,lastClearPosition:new Vector4(8,20,30,1),
    lastClearFacing:facing,lastClearanceProbePosition:s.entity,positionOriginDelta:new Vector4(),positionLastTarget:s.physics,positionReadbackPending:false,
    positionWritesIssued:0,positionReadbacks:0,positionRefusals:0,positionReadbackDistance:0,positionOriginDivergence:0,ticks:0,filterWrites:0,velocityWrites:0,maxObservedEntityRadius:0,
    maxPositionOriginDivergence:0,maxPositionReadbackDistance:0,elapsed:0,clearanceClock:0,clearanceProbes:0,capsuleHeight:1.8,capsuleRadius:.4});
  const p={isPlayer:true,nccCollisionFlightProbe:defaults(),GetGame:()=>0,GetEntityID:()=>1,IsDead:()=>!!s.dead,GetWorldPosition:()=>{s.entityReads++;return s.entity;},GetWorldOrientation:()=>facing,
    NCCFlightProbeIsFilter:v=>!!v?.valid,NCCFlightProbeIsVelocity:()=>true,NCCFlightProbeZeroVelocity:()=>({}),
    NCCFlightProbeZeroFilter:()=>({valid:true,zero:true}),NCCFlightCameraBefore:()=>false,NCCFlightCameraStartActive:()=>{},
    NCCFlightProbeCameraFacing:()=>facing,NCCFlightInput(){s.reads++;return s.packet;},
    NCCFlightProbeWriteFilter(si,v){if(v.zero){s.zero++;if(s.afterZero)s.afterZero();return true;}s.restores++;s.restoreArgs.push({si,v});return s.accepted;},
    NCCFlightClearanceInitialize(){s.initialized=true;return !s.initFails;},NCCFlightClearanceVerifyControls(si,pos){s.controlPosition=pos;return s.controls;},
    NCCFlightClearanceAt(si,pos){s.queries.push(pos);return s.clear?s.clear(pos):s.controls;}};
  const interactionBoard={GetBool:k=>{s.interactionReads++;return k==='zoom'?s.zoom:s.device;},GetInt:()=>{s.interactionReads++;return s.workspotBB;}};
  const workspots={IsActorInWorkspot:actor=>{assert.equal(actor,p);s.workspotReads++;return s.workspot;}};
  const si={owner:p,executionOwner:p,localBlackboard:interactionBoard,GetWorkspotSystem:()=>workspots,
    IsMountedToObject:()=>!!s.mounted,IsPlayerInBraindance:()=>!!s.braindance,IsSceneAnimationActive:()=>!!s.scene,IsOnGround:()=>s.grounded,
    SetStateVectorParameter(){s.velocity++;return true;},GetStateVectorParameter(k){if(k==='pos')s.positionReads++;return k==='pos'?(s.undefinedPosition?undefined:{type:s.type||'Vector4',value:s.physics}):{type:'Vector4'};},
    GetCameraSystem:()=>({GetActiveCameraRight:()=>new Vector4(1,0,0,0),GetActiveCameraForward:()=>new Vector4(0,1,0,0)}),
    NCCFlightWritePosition(v){s.positions++;s.physics=new Vector4(v.X,v.Y,v.Z,1);s.entity=s.physics;return !s.rejectPosition;}};
  const board={GetBool:()=>s.menu,RegisterListenerBool(id,owner,callback){if(s.registrationFails)return null;owner[callback](s.menu);return {};}};
  class Trace {constructor(){this.samples=[];this.recovery=new Vector4();}}
  const c=vm.createContext({Vector4,Vector3,FromVariant:v=>v.value,AsPlayer:v=>v?.isPlayer?v:null,IsDefined:v=>v!==null&&v!==undefined,Equals:(a,b)=>a===b,NotEquals:(a,b)=>a!==b,
    ArrayPush:(a,v)=>a.push(v),ArraySize:a=>a.length,ToString:v=>{s.formats++;return String(v);},FloatToStringPrec:(v,n)=>{s.formats++;return v.toFixed(n);},
    StrLeft:(v,n)=>{s.formats++;return v.slice(0,n);},
    NCCFlightTransitionTrace:Trace,NCCFlightTransitionSample:class{constructor(){s.sampleAllocations++;}},
    AbsF:Math.abs,MinF:Math.min,MaxF:Math.max,ClampF:(n,a,b)=>Math.max(a,Math.min(n,b)),VariantTypeName:v=>v?.type||'physicsSimulationFilter',NameToString:v=>v,
    Quaternion:{ToEulerAngles:v=>v},GetAllBlackboardDefs:()=>({UI_System:{IsInMenu:'menu'},PlayerStateMachine:{IsUIZoomDevice:'zoom',IsInteractingWithDevice:'device',IsInWorkspot:'workspot'}}),EngineTime:{ToFloat:v=>v},
    GameInstance:{GetBlackboardSystem:()=>({Get:()=>board,GetLocalInstanced:()=>s.missingInteractionBoard?null:interactionBoard}),GetWorkspotSystem:()=>workspots,
      GetSimTime:()=>s.time,GetDelaySystem:()=>({DelayCallbackNextFrame:cb=>s.callbacks.push(cb)}),
      GetTeleportationFacility:()=>({Teleport(owner,pos){assert.equal(owner,p);s.teleports.push(pos);if(!s.deferTeleport){s.entity=pos;s.physics=pos;}}})},
    physicsStateValue:{Position:'pos',LinearVelocity:'vel'},NCCCollisionFlightTransitionWatchdog:class{},
    NCCCollisionFlightProbeState:class{constructor(){Object.assign(this,defaults(),{focusEpochValid:false});}},
    wrappedMethod:()=>{if(s.afterOriginal)s.afterOriginal();}});
  for(const [name,args]of Object.entries(methods))p['NCCFlightProbe'+name]=vm.runInContext(`(function(${args}){${body('NCCFlightProbe'+name)}})`,c).bind(p);
  for(const [name,args]of Object.entries({Initialize:'',Advance:'dt',Next:'',Available:'',Freeze:'reason',Vector:'value',Report:''}))
    Trace.prototype['Trace'+name]=vm.runInContext(`(function(${args}){${body('Trace'+name)}})`,c);
  for(const [name,args]of Object.entries({OwnsContext:'scriptInterface',Record:'scriptInterface,phase,physics,entity,valid,typeName',
    Snapshot:'scriptInterface,phase',Before:'timeDelta,scriptInterface',After:'scriptInterface',EndCallback:'',State:'scriptInterface,stateName,machineName,entering'}))
    p['NCCFlightTrace'+name]=vm.runInContext(`(function(${args}){${body('NCCFlightTrace'+name)}})`,c).bind(p);
  const sc={IsStateActive:(m,n)=>s.current&&m==='Locomotion'&&n==='stand'};
  const transition={GetStateName:()=> 'stand',GetStateMachineName:()=> 'Locomotion',
    GetStaticBoolParameterDefault:()=>{s.static=(s.static||0)+1;return !!s.zeroPreset;},GetStaticFloatParameterDefault:(n,fallback)=>fallback,
    SetCollisionFilter(x){assert.equal(x,si);s.normal++;if(!s.captureFails)p.NCCFlightProbeCaptureFilter(si,{valid:true},!s.zeroPreset);if(s.afterCapture)s.afterCapture();}};
  const tick=vm.runInContext(`(function(timeDelta,stateContext,scriptInterface){${body('OnUpdate')}})`,c).bind(transition);
  const exit=vm.runInContext(`(function(stateContext,scriptInterface){${body('OnExit')}})`,c).bind(transition);
  const forcedExit=vm.runInContext(`(function(stateContext,scriptInterface){${body('OnForcedExit')}})`,c).bind(transition);
  p.nccCollisionFlightProbe.interfaceRef=si;p.nccCollisionFlightProbe.capturedInterface=si;
  return{s,p,si,sc,get q(){return p.nccCollisionFlightProbe;},tick(dt=.02,x=si){tick(dt,sc,x);},exit(){exit(sc,si);},forcedExit(){forcedExit(sc,si);},
    trace(){const t=new Trace();t.TraceInitialize();t.running=true;t.stop='running';t.fromState=t.toState='stand';t.fromMachine=t.toMachine='Locomotion';this.q.transitionTrace=t;return t;},
    start(v=packet()){return p.NCCFlightProbePrepare(v);},active(){this.q.active=true;this.q.requested=true;p.NCCFlightProbeEnsureMenuListener();return this;}};
}
{
  const f=fixture();f.p.nccCollisionFlightProbe=null;assert.match(f.start(packet(7,768)),/Requested/);f.s.packet=packet(7,768);f.tick();
  assert.equal(f.s.normal,0);assert.equal(f.q.prepareElapsed,0);f.s.packet=packet(7);f.tick();assert.equal(f.q.prepared,true);
  assert.equal(f.s.positions,0);f.tick();assert.equal(f.q.active,true);assert.equal(f.s.normal,1);assert.equal(f.s.positions,1);
}
for(const fail of ['zeroPreset','captureFails','before','after','menu']){
  const f=fixture();f.start();if(fail==='zeroPreset'||fail==='captureFails')f.s[fail]=true;
  if(fail==='before')f.s.afterOriginal=()=>{f.s.current=false;};if(fail==='after')f.s.afterCapture=()=>{f.s.current=false;};
  if(fail==='menu')f.s.afterCapture=()=>f.p.NCCFlightProbeMenuChanged(true);
  f.tick();assert.equal(f.q.requested,false,fail);assert.equal(f.s.zero,0);const attempts=f.s.normal;f.s.afterCapture=null;f.tick();assert.equal(f.s.normal,attempts);
}
for(const value of [packet(4),packet(3,256),packet(3,512+4096),packet(3,512+32768)]){
  const f=fixture();f.start();f.s.packet=value;f.tick();assert.equal(f.q.requested,false);assert.equal(f.s.normal,0);
}
{
  const f=fixture();f.start(packet(9));assert.equal(f.q.focusEpoch,9);assert.match(f.start(packet(10)),/already active or preparing/);
  assert.equal(f.q.focusEpoch,9);f.p.NCCFlightProbeStopHere();assert.equal(f.q.requested,false);assert.match(f.p.NCCFlightProbeReturn(),/no active flight session/);
  f.start();f.s.grounded=false;for(let i=0;i<10;i++)f.tick(.5);assert.match(f.q.status,/5-second/);
  f.start();f.q.prepareCallbacks=4095;f.tick(0);assert.match(f.q.status,/callback limit/);
}
for(const cause of ['menu','focus']){
  const f=fixture().active();if(cause==='menu'){f.s.menu=true;f.p.NCCFlightProbeMenuChanged(true);}else f.s.packet=packet(4);
  f.tick();assert.equal(f.q.paused,true);assert.equal(f.q.active,true);assert.equal(f.s.restores,0);assert.equal(f.s.teleports.length,0);
  f.s.menu=false;f.s.packet=packet(5);const reads=f.s.reads;f.tick();assert.equal(f.q.paused,true);assert.equal(f.s.reads,reads);
  f.p.NCCFlightProbeResume(packet(5));f.s.packet=packet(6);f.tick();assert.equal(f.q.paused,true);assert.equal(f.q.resumeRequested,false);
  f.p.NCCFlightProbeResume(packet(6));f.s.packet=packet(6,513);f.tick();assert.equal(f.q.paused,true);assert.equal(f.q.resumeRequested,true);
  f.s.packet=packet(6);f.tick();assert.equal(f.q.paused,false);
}
{
  const f=fixture().active();f.p.NCCFlightProbeStopHere();f.tick();assert.equal(f.q.active,false);assert.equal(f.q.paused,false);
  assert.equal(f.s.teleports.length,0);assert.equal(f.s.restores,1);assert.equal(f.s.positions,0);assert.match(f.p.NCCFlightProbeReturn(),/no active flight session/);
}
{
  const f=fixture().active();f.s.clear=pos=>pos.X!==10;f.p.NCCFlightProbeStopHere();f.tick();assert.equal(f.q.active,true);assert.equal(f.q.paused,true);
  assert.equal(f.q.exitRequest,0);assert.equal(f.s.restores,0);assert.equal(f.s.teleports.length,0);const queries=f.s.queries.length;
  f.s.clear=()=>true;f.tick();assert.equal(f.s.queries.length,queries,'blocked Stop never auto-retries');assert.equal(f.q.active,true);assert.equal(f.s.reads,0);
}
for(const clear of [true,false]){
  const f=fixture().active();f.s.clear=()=>clear;f.p.NCCFlightProbeReturn();f.tick();assert.equal(f.s.teleports.length,clear?1:0);
  if(clear){assert.deepEqual(f.s.teleports[0],f.q.start);assert.equal(f.q.active,false);}else{assert.equal(f.q.paused,true);assert.equal(f.q.exitRequest,0);f.tick();assert.equal(f.s.teleports.length,0);}
}
{
  const f=fixture().active();f.q.elapsed=61;f.q.positionWritesIssued=40000;f.q.start=new Vector4(-200,20,30,1);f.s.packet=packet(3,513);f.tick();
  assert.equal(f.q.active,true);assert.equal(f.s.positions,1);assert.equal(f.q.positionWritesIssued,40001);assert.equal(f.s.teleports.length,0);
  f.q.positionWritesIssued=2147483647;f.q.inputChecks=2147483647;f.tick();assert.equal(f.q.positionWritesIssued,2147483647);assert.equal(f.q.inputChecks,2147483647);
}
{
  const f=fixture().active(),anchor=f.q.start;f.p.NCCFlightProbeSuspendForTransition(f.si);assert.equal(f.q.active,false);assert.equal(f.q.transitionPending,true);
  assert.equal(f.s.restores,1);assert.equal(f.s.teleports.length,0);f.p.NCCFlightProbeObserveStateFilter(f.si,'stand','Locomotion',true);
  assert.equal(f.q.active,true);assert.equal(f.q.transitionPending,false);assert.equal(f.q.paused,false);assert.equal(f.q.start,anchor);assert.equal(f.s.teleports.length,0);
}
{
  const f=fixture().active();f.s.clear=pos=>pos.X!==10;f.p.NCCFlightProbeSuspendForTransition(f.si);assert.equal(f.s.teleports.length,1);
  assert.equal(f.s.teleports[0],f.q.lastClearPosition);assert.equal(f.q.transitionPending,false);assert.equal(f.q.arrivalPending,true);const reads=f.s.reads;
  f.p.NCCFlightProbeObserveStateFilter(f.si,'stand','Locomotion',true);assert.equal(f.q.active,false);assert.equal(f.s.reads,reads);
}
{
  const f=fixture().active();f.s.clear=()=>false;f.p.NCCFlightProbeSuspendForTransition(f.si);assert.equal(f.s.teleports.length,0);assert.equal(f.s.restores,1);
  assert.equal(f.q.active,false);assert.equal(f.q.transitionPending,false);assert.equal(f.q.clearanceFailed,true);assert.match(f.q.status,/clearance unconfirmed/);
}
{
  const f=fixture().active();f.p.NCCFlightProbeSuspendForTransition(f.si);const writes=f.s.restores;f.p.NCCFlightProbeExpireTransition(f.q,f.q.transitionSerial);
  assert.equal(f.q.transitionPending,false);assert.equal(f.s.restores,writes,'watchdog never writes physics');
}
{
  const f=fixture().active();f.s.accepted=false;f.p.NCCFlightProbeObserveStateFilter(f.si,'stand','Locomotion',false);
  assert.equal(f.q.active,true);assert.equal(f.q.interfaceRef,f.si);assert.equal(f.q.stopRequested,true);assert.equal(f.q.restoreUnconfirmed,true);
  f.s.accepted=true;f.tick();assert.equal(f.q.active,false);assert.equal(f.q.restoreUnconfirmed,false);
}
for(const invalid of ['type','origin','W','NaN','readback']){
  const f=fixture().active();if(invalid==='type')f.s.type='None';if(invalid==='origin')f.s.physics=new Vector4(12,20,30,1);
  if(invalid==='W')f.s.physics=new Vector4(10,20,30,0);if(invalid==='NaN')f.s.physics=new Vector4(NaN,20,30,1);
  if(invalid==='readback'){f.q.positionReadbackPending=true;f.q.positionLastTarget=new Vector4(50,20,30,1);}
  f.p.NCCFlightProbeStopHere();f.p.NCCFlightProbeProcessExit(f.si);assert.equal(f.s.restores,0,invalid);assert.equal(f.s.teleports.length,0,invalid);
  assert.equal(f.q.paused,true);assert.equal(f.s.queries.length,0,'invalid actual origin cannot be treated as clear');
  f.p.NCCFlightProbeRestore(f.si,'forced exit',true);assert.equal(f.s.teleports.length,1);assert.equal(f.s.teleports[0],f.q.lastClearPosition);
}
{
  const f=fixture().active();f.p.NCCFlightProbeObserveStateFilter({...f.si},'stand','Locomotion',false);
  assert.equal(f.q.active,false);assert.equal(f.q.restoreUnconfirmed,true);
  assert.equal(f.s.restores,0);assert.equal(f.s.teleports.length,0);
  assert.match(f.start(),/restoration is unconfirmed/,'unexpected ownership must block another session');
}
{
  const f=fixture();f.start();f.tick();f.s.controls=false;f.tick();assert.equal(f.s.positions,0);assert.equal(f.s.restores,1);
  assert.equal(f.s.teleports.length,0);assert.equal(f.q.active,false);assert.equal(f.q.clearanceFailed,true);
}
{
  const f=fixture();f.tick();assert.equal(f.s.reads,0);assert.equal(f.s.static||0,0);assert.equal(f.s.queries.length,0);
  f.q.restoreUnconfirmed=true;assert.match(f.start(),/restoration is unconfirmed/);f.q.ownFilterWrite=true;
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);assert.equal(f.q.restoreUnconfirmed,true);f.q.ownFilterWrite=false;
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);assert.equal(f.q.restoreUnconfirmed,false);
}
// These five vanilla states preserve the normal filter/update/exit callback
// chain. Their real handoff must keep the current trip, including paused trips.
const addedStates=['aimWalk','doubleJump','chargeJump','hoverJump','regularLand'];
for(const stateName of addedStates)for(const paused of [false,true]){
  const f=fixture().active(),anchor=f.q.start;f.q.paused=paused;
  assert.equal(f.p.NCCFlightProbeAllowed(stateName,'Locomotion'),true,stateName);
  f.p.NCCFlightProbeSuspendForTransition(f.si);
  assert.equal(f.q.active,false);assert.equal(f.q.transitionPending,true);assert.equal(f.s.restores,1);
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);
  f.p.NCCFlightProbeObserveStateFilter(f.si,stateName,'Locomotion',true);
  assert.equal(f.q.active,true,stateName);assert.equal(f.q.transitionPending,false);
  assert.equal(f.q.paused,paused);assert.equal(f.q.start,anchor);assert.equal(f.s.teleports.length,0);
  f.p.NCCFlightProbeUpdate(.02,f.sc,f.si,stateName,'Locomotion');
  assert.equal(f.q.active,true);assert.equal(f.s.positions,1);assert.equal(f.s.teleports.length,0);
  f.p.NCCFlightProbeStopHere();f.p.NCCFlightProbeUpdate(.02,f.sc,f.si,stateName,'Locomotion');
  assert.equal(f.q.active,false);assert.equal(f.s.restores,2);assert.equal(f.s.teleports.length,0);
}
for(const [stateName,machine] of [
  ['deathLand','Locomotion'],['hardLand','Locomotion'],['veryHardLand','Locomotion'],['knockdown','Locomotion'],
  ['workspot','Locomotion'],['bodySlamJump','Locomotion'],['ladderJump','Locomotion'],['dodgeAir','Locomotion'],
  ['aimWalk','LocomotionLowGravity'],['jump','LocomotionSwimming'],['stand','Scene'],
]){
  const f=fixture().active();assert.equal(f.p.NCCFlightProbeAllowed(stateName,machine),false);
  f.p.NCCFlightProbeSuspendForTransition(f.si);const writes=f.s.zero;
  f.p.NCCFlightProbeObserveStateFilter(f.si,stateName,machine,true);
  assert.equal(f.q.active,false);assert.equal(f.q.requested,false);assert.equal(f.q.transitionPending,false);
  assert.equal(f.s.zero,writes,'unsupported handoff cannot disable collision again');
  assert.equal(f.s.teleports.length,0);assert.match(f.q.status,new RegExp(machine+'/'+stateName));
}
for(const unsafe of ['scene','mounted','dead','timeout']){
  const f=fixture().active();f.p.NCCFlightProbeSuspendForTransition(f.si);
  if(unsafe==='scene')f.si.IsSceneAnimationActive=()=>true;
  if(unsafe==='mounted')f.s.mounted=true;if(unsafe==='dead')f.s.dead=true;if(unsafe==='timeout')f.s.time+=.1;
  f.p.NCCFlightProbeObserveStateFilter(f.si,'aimWalk','Locomotion',true);
  assert.equal(f.q.active,false,unsafe);assert.equal(f.s.zero,0);assert.equal(f.s.teleports.length,0);
}
function dodgeDecision(f, si=f.si, machine='Locomotion', originalResult=true, method='WantsToDodge') {
  const calls=[];
  const c=vm.createContext({IsDefined:v=>v!==null&&v!==undefined,Equals:(a,b)=>a===b,AsPlayer:v=>v?.isPlayer?v:null,
    wrappedMethod:(...args)=>{calls.push(args);return originalResult;}});
  const decision=vm.runInContext(`(function(stateContext,scriptInterface){${body(method)}})`,c);
  const before={reads:f.s.reads,zero:f.s.zero,restores:f.s.restores,positions:f.s.positions,velocity:f.s.velocity};
  const result=decision.call({GetStateMachineName:()=>machine},f.sc,si);
  assert.deepEqual({reads:f.s.reads,zero:f.s.zero,restores:f.s.restores,positions:f.s.positions,velocity:f.s.velocity},before,
    'dodge gating only reads script ownership; no native input polling or physics writes');
  for(const args of calls){assert.equal(args.length,2);assert.equal(args[0],f.sc);assert.equal(args[1],si);}
  return {result,calls:calls.length};
}
for(const state of ['active','paused','cleanup']){
  const f=fixture().active();f.q.paused=state==='paused';
  if(state==='cleanup'){f.q.stopRequested=true;f.q.restoreUnconfirmed=true;f.q.requested=false;}
  assert.deepEqual(dodgeDecision(f),{result:false,calls:0},state);
}
for(const state of ['inactive','preparing','pending','missingProbe','staleInterface','missingInterface','foreignOwner','foreignPlayer','otherMachine']){
  const f=fixture();let si=f.si,machine='Locomotion';
  if(state==='preparing'){f.q.requested=true;f.q.preparePending=true;}
  if(state==='pending'){f.q.requested=true;f.q.transitionPending=true;}
  if(state==='missingProbe')f.p.nccCollisionFlightProbe=null;
  if(state==='staleInterface'){f.q.active=true;si={...f.si};}
  if(state==='missingInterface'){f.q.active=true;si=null;}
  if(state==='foreignOwner'){f.q.active=true;si={...f.si,owner:{}};}
  if(state==='foreignPlayer'){f.q.active=true;si={...f.si,owner:fixture().p};}
  if(state==='otherMachine'){f.q.active=true;machine='LocomotionLowGravity';}
  for(const originalResult of [false,true])assert.deepEqual(dodgeDecision(f,si,machine,originalResult),{result:originalResult,calls:1},state);
}
for(const stop of ['NCCFlightProbeStopHere','NCCFlightProbeReturn']){
  const f=fixture().active();assert.deepEqual(dodgeDecision(f),{result:false,calls:0});
  f.p[stop]();f.tick();assert.equal(f.q.active,false);
  assert.deepEqual(dodgeDecision(f),{result:true,calls:1},'normal dash immediately returns after '+stop);
}
function samples(t){return Array.from({length:t.count},(_,i)=>t.samples[(t.next-t.count+i+32)%32]);}
{
  const f=fixture();f.start(packet(3,768));const t=f.q.transitionTrace;
  assert.equal(t.running,false);assert.equal(t.samples.length,32);assert.equal(f.s.sampleAllocations,32);
  f.s.packet=packet(3,768);for(let i=0;i<5;i++)f.tick();assert.equal(t.callbacks,0);assert.equal(t.events,0);
  f.s.packet=packet();f.tick();assert.equal(t.running,false,'preparation alone does not start recording');
  f.tick();assert.equal(t.running,true);assert.equal(samples(t)[0].phase,'activated');assert.equal(f.s.formats,0);
}
{
  const f=fixture().active(),t=f.trace(),allocated=[...t.samples];
  for(let i=0;i<100;i++){f.s.time=i;f.p.NCCFlightTraceSnapshot(f.si,'ring');}
  assert.equal(t.count,32);assert.equal(t.events,100);assert.deepEqual(t.samples,allocated);
  assert.equal(samples(t)[0].time,68);assert.equal(samples(t).at(-1).time,99);
  assert.equal(f.s.sampleAllocations,32,'recording reuses preallocated sample objects');assert.equal(f.s.formats,0);
  const report=t.TraceReport();assert.match(report,/latestUpdateDt/);assert.match(report,/events=100\/8192/);assert(f.s.formats>0);
  t.TraceFreeze('first-refusal');const retained=JSON.stringify(t.samples),reads=f.s.positionReads;
  f.p.NCCFlightTraceSnapshot(f.si,'late');assert.equal(JSON.stringify(t.samples),retained);assert.equal(f.s.positionReads,reads);
}
for(const cap of ['events','callbacks','time']){
  const f=fixture().active(),t=f.trace();
  if(cap==='events'){
    for(let i=0;i<8192;i++)f.p.NCCFlightTraceSnapshot(f.si,'burst');
    const reads=f.s.positionReads;f.p.NCCFlightTraceSnapshot(f.si,'past-cap');
    assert.equal(t.events,8192);assert.equal(f.s.positionReads,reads,'event cap is checked before native getters');
  }else if(cap==='callbacks'){
    for(let i=0;i<4096;i++)f.p.NCCFlightTraceBefore(0,f.si);
    assert.equal(t.callbacks,4096);assert.equal(f.s.positionReads,0);
  }else{
    for(let i=0;i<30;i++)f.p.NCCFlightTraceBefore(1,f.si);
    assert.equal(t.elapsed,30);assert.equal(t.callbacks,30);
  }
  assert.equal(t.running,false);const events=t.events,reads=f.s.positionReads;
  f.p.NCCFlightTraceSnapshot(f.si,'after-budget');assert.equal(t.events,events);assert.equal(f.s.positionReads,reads);
}
for(const stale of ['interface','owner','inactive']){
  const f=fixture().active(),t=f.trace();let si=f.si;
  if(stale==='interface')si={...f.si};if(stale==='owner')si={...f.si,owner:{}};if(stale==='inactive')f.q.active=false;
  const before={p:f.s.positionReads,e:f.s.entityReads};f.p.NCCFlightTraceSnapshot(si,'stale');
  assert.deepEqual({p:f.s.positionReads,e:f.s.entityReads},before,'invalid context gets no new physics/entity reads');
  assert.equal(samples(t)[0].owned,false);assert.equal(samples(t)[0].physicsValid,false);assert.equal(t.running,false);
}
{
  const f=fixture().active(),t=f.trace();t.watch=4;
  for(let i=0;i<5;i++){
    const reads=f.s.positionReads;f.tick();
    assert.equal(f.s.positionReads-reads,i<4?3:1,'only four watched callbacks add pre/post snapshots');
  }
  assert.equal(t.watch,0);assert.equal(samples(t).filter(x=>x.phase==='before-vanilla-update').length,4);
  assert.equal(samples(t).filter(x=>x.phase==='after-vanilla-update').length,4);
  assert.equal(f.s.formats,0);assert.equal(f.s.sampleAllocations,32);
}
// Engine Teleport enqueues a request. A deferred engine mock must record the
// old observed position after issuance, not silently report requested arrival.
for(const deferred of [false,true]){
  const f=fixture().active(),t=f.trace();f.s.deferTeleport=deferred;f.s.clear=pos=>pos.X!==10;
  f.exit();assert.equal(f.q.transitionPending,false);assert.equal(f.q.arrivalPending,true);assert.equal(f.s.teleports.length,1);
  const before=samples(t).find(x=>x.phase==='before-teleport'),after=samples(t).find(x=>x.phase==='after-teleport');
  assert.equal(before.physics.X,10);assert.equal(after.physics.X,deferred?10:8);assert.equal(after.recovery.X,8);
  assert.equal(after.target.X,10,'snapshot does not adopt requested recovery as observed target');
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);f.p.NCCFlightTraceState(f.si,'sprint','Locomotion',true);
  f.p.NCCFlightProbeObserveStateFilter(f.si,'sprint','Locomotion',true);
  assert.equal(f.q.active,false);assert.equal(f.q.positionLastTarget.X,10,'queued destination never replaces movement readback target');
  f.tick(.037);assert.equal(f.q.arrivalPending,true,'same-time arrival cannot confirm completion');
  f.s.time+=.04;f.tick(.037);assert.equal(f.q.arrivalPending,deferred);
  assert.equal(f.q.positionRefusals,0);assert.equal(f.s.zero,0);assert.equal(f.s.positions,0);assert.equal(f.q.active,false);
  if(deferred){f.s.physics=f.s.entity=f.q.arrivalDestination;f.s.time+=.04;f.tick();}
  assert.equal(f.q.arrivalUnconfirmed,false);assert.equal(f.q.requested,false);assert.equal(f.s.teleports.length,1);
}
{
  const f=fixture().active(),t=f.trace();f.q.positionReadbackPending=true;f.q.positionLastTarget=new Vector4(7,20,30,1);
  f.tick(.037);assert.equal(f.q.positionRefusals,1);assert.equal(t.stop,'first-refusal');
  const failed=samples(t).find(x=>x.phase==='readback-failed');assert.equal(failed.dt,.037);assert.equal(failed.error.X,3);
  assert.equal(samples(t).at(-1).phase,'refusal','first fault remains frozen before cleanup');
}
{
  const f=fixture().active(),t=f.trace();t.watch=4;f.q.paused=true;f.q.positionReadbackPending=true;
  f.q.positionLastTarget=new Vector4(8,20,30,1);f.q.target=f.q.positionLastTarget;
  f.s.afterOriginal=()=>{f.s.physics=f.s.entity=new Vector4(8,20,30,1);};
  f.tick(.04);assert.equal(samples(t).find(x=>x.phase==='before-vanilla-update').physics.X,10);
  assert.equal(samples(t).find(x=>x.phase==='after-vanilla-update').physics.X,8);
  assert.equal(samples(t).find(x=>x.phase==='readback').error.X,0);assert.equal(f.q.positionRefusals,0);
}
// Diagnostic getters must not change accepted movement, control decisions,
// collision restoration, queued destinations, or the existing refusal outcome.
for(const action of ['move','stop','return','recovery','refusal']){
  const outputs=[];
  for(const trace of [false,true]){
    const f=fixture().active();if(trace)f.trace();
    if(action==='move'){f.s.packet=packet(3,513);f.tick();}
    if(action==='stop'){f.p.NCCFlightProbeStopHere();f.tick();}
    if(action==='return'){f.p.NCCFlightProbeReturn();f.tick();}
    if(action==='recovery'){f.s.clear=pos=>pos.X!==10;f.s.deferTeleport=true;f.exit();}
    if(action==='refusal'){f.q.positionReadbackPending=true;f.q.positionLastTarget=new Vector4(7,20,30,1);f.tick();}
    outputs.push({active:f.q.active,paused:f.q.paused,requested:f.q.requested,transition:f.q.transitionPending,status:f.q.status,
      zero:f.s.zero,restores:f.s.restores,velocity:f.s.velocity,positions:f.s.positions,teleports:f.s.teleports,
      queries:f.s.queries,packetReads:f.s.reads,refusals:f.q.positionRefusals,target:f.q.target});
  }
  assert.deepEqual(outputs[0],outputs[1],action+' diagnostics are observational');
}
function queueReturn(f=fixture().active()) {
  f.s.deferTeleport=true;f.p.NCCFlightProbeReturn();f.tick();
  assert.equal(f.s.teleports.length,1);assert.equal(f.q.arrivalUnconfirmed,true);return f;
}
function nativeEffects(f){return {zero:f.s.zero,positions:f.s.positions,velocity:f.s.velocity,teleports:f.s.teleports.length,restores:f.s.restores};}
{
  const f=queueReturn(),submitted=f.q.arrivalDestination,serial=f.q.arrivalSerial,effects=nativeEffects(f);
  assert.equal(f.q.active,false);assert.equal(f.q.requested,false);assert.equal(f.q.transitionPending,false);
  assert.match(f.start(),/awaiting the queued/);assert.match(f.p.NCCFlightProbeResume(packet()),/unresolved/);
  for(let i=0;i<3;i++){f.p.NCCFlightProbeStopHere();f.p.NCCFlightProbeReturn();f.p.NCCFlightProbeMenuChanged(true);f.p.NCCFlightProbeMenuChanged(false);}
  assert.equal(f.q.arrivalDestination,submitted);assert.equal(f.q.arrivalSerial,serial);assert.equal(f.q.arrivalPending,true);
  f.s.packet=packet(99);f.tick();assert.deepEqual(nativeEffects(f),effects);assert.equal(f.s.reads,0,'arrival observation never polls raw input');
  f.s.time+=.02;f.s.physics=f.s.entity=submitted;f.tick();assert.equal(f.q.arrivalUnconfirmed,false);assert.equal(f.q.active,false);
  assert.equal(f.q.requested,false);assert.equal(f.q.prepared,false);assert.match(f.q.status,/arrival observed/);
  assert.deepEqual(nativeEffects(f),effects);assert.match(f.start(packet(99)),/Requested/,'a separate Start is necessary');
}
{
  const f=fixture().active();f.s.accepted=false;queueReturn(f);
  const destination=f.q.arrivalDestination,serial=f.q.arrivalSerial,baseline=f.q.arrivalRestoreFilter,issued=f.q.arrivalIssuedAt;
  f.q.baselineFilter={valid:true,replaced:true};
  assert.equal(f.q.active,true);assert.equal(f.q.restoreUnconfirmed,true);assert.equal(f.s.positions,0);
  const velocity=f.s.velocity;
  for(let i=0;i<3;i++){
    f.s.time+=.02;f.tick();f.p.NCCFlightProbeReturn();f.p.NCCFlightProbeStopHere();
    f.p.NCCFlightProbeRestoreAt(f.si,new Vector4(90,90,90,1),{Yaw:0,Pitch:0,Roll:0},true,'second request');
  }
  assert.equal(f.s.teleports.length,1);assert.equal(f.q.arrivalDestination,destination);assert.equal(f.q.arrivalSerial,serial);
  assert.equal(f.q.arrivalIssuedAt,issued);assert.equal(f.s.zero,0);assert.equal(f.s.positions,0);assert.equal(f.s.velocity,velocity);
  for(const call of f.s.restoreArgs){assert.equal(call.si,f.si);assert.equal(call.v,baseline);}
  assert.match(f.start(),/collision cleanup/);assert.equal(f.s.positionReads,0,'failed collision cleanup performs no arrival physics reads');
  f.s.accepted=true;f.tick();assert.equal(f.q.active,false);assert.equal(f.q.restoreUnconfirmed,false);assert.equal(f.q.arrivalUnconfirmed,true);
  f.s.physics=f.s.entity=destination;f.s.time+=.02;f.tick();assert.equal(f.q.arrivalUnconfirmed,false);
}
{
  const f=fixture().active();f.s.accepted=false;queueReturn(f);const restores=f.s.restores;
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true,zero:true},false);
  for(let i=0;i<3;i++){f.s.time+=.02;f.tick();}
  assert.equal(f.s.restores,restores,'a later original ZERO invalidates old-baseline retry authority even on the same interface');
  assert.equal(f.q.arrivalUnconfirmed,true);assert.equal(f.q.restoreUnconfirmed,true);assert.equal(f.q.arrivalPending,false);
  assert.equal(f.q.active,false);assert.equal(f.q.interfaceRef,null);
  for(const method of ['WantsToDodge','EnterCondition','ToSprint','ToCrouchSprint'])
    assert.deepEqual(dodgeDecision(f,f.si,'Locomotion',true,method),{result:true,calls:1},'original ZERO revokes our movement veto');
  assert.match(f.start(),/collision cleanup/);
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);assert.equal(f.q.active,false);assert.equal(f.q.restoreUnconfirmed,false);
  assert.equal(f.q.arrivalUnconfirmed,true,'normal collision capture is not queued arrival evidence');
}
for(const stale of ['interface','owner','state','capture','zero','dead','mounted','braindance','scene','machine']){
  const f=queueReturn();f.s.time+=.02;let si=f.si,state='stand',machine='Locomotion';
  if(stale==='interface')si={...f.si};if(stale==='owner')si={...f.si,owner:{}};
  if(stale==='state')f.s.current=false;if(stale==='capture')f.q.capturedFilter={valid:false};
  if(stale==='zero')f.q.capturedNormal=false;if(['dead','mounted','braindance','scene'].includes(stale))f.s[stale]=true;if(stale==='machine')machine='LocomotionLowGravity';
  const reads=f.s.positionReads,entityReads=f.s.entityReads,effects=nativeEffects(f);
  f.p.NCCFlightProbeArrivalTick(.02,f.sc,si,state,machine);
  assert.equal(f.s.positionReads,reads,stale);assert.equal(f.s.entityReads,entityReads,stale);assert.deepEqual(nativeEffects(f),effects);
  assert.equal(f.q.arrivalPending,!['owner','dead','mounted','braindance','scene'].includes(stale));assert.equal(f.q.arrivalUnconfirmed,true);
}
// A finishing outgoing callback must not permanently suppress the new state's
// later observation. This reproduces the live callback1/elapsed0/distance-1
// signature without assuming that every such signature had the same cause.
{
  const f=queueReturn(),effects=nativeEffects(f),reads=f.s.positionReads,entityReads=f.s.entityReads;
  f.s.current=false;f.tick();
  assert.equal(f.q.arrivalCallbacks,1);assert.equal(f.q.arrivalElapsed,0);assert.equal(f.q.arrivalDistance,-1);
  assert.equal(f.q.arrivalObservationWait,'same-time');
  assert.equal(f.q.arrivalPending,true);assert.equal(f.s.positionReads,reads);assert.equal(f.s.entityReads,entityReads);
  f.s.time+=.02;f.tick();assert.equal(f.q.arrivalPending,true,'unready outgoing state stays pending after time advances');
  assert.equal(f.s.positionReads,reads);assert.equal(f.s.entityReads,entityReads);
  const startedAt=f.q.arrivalPollStartedAt,callbacks=f.q.arrivalCallbacks;
  for(let i=0;i<3;i++)assert.match(f.start(),/awaiting the queued/);
  assert.equal(f.q.arrivalPollStartedAt,startedAt);assert.equal(f.q.arrivalCallbacks,callbacks,'commands cannot extend an active poll');
  f.s.current=true;f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);
  f.s.physics=f.s.entity=f.q.arrivalDestination;f.s.time+=.02;f.tick();
  assert.equal(f.q.arrivalUnconfirmed,false);assert.equal(f.q.active,false);assert.equal(f.q.requested,false);
  assert.equal(f.q.arrivalObservationWait,'None','valid observation clears only the transient wait marker');
  assert.deepEqual(nativeEffects(f),effects);assert.equal(f.s.teleports.length,1);
}
// Missing context/filter capture never permits a physics read. A subsequent
// normal capture can make the same bounded observer eligible, without rearming.
for(const missing of ['context','capture']){
  const f=queueReturn(),effects=nativeEffects(f);f.s.time+=.02;
  if(missing==='capture')f.q.capturedInterface=null;
  f.p.NCCFlightProbeArrivalTick(.02,missing==='context'?null:f.sc,f.si,'stand','Locomotion');
  assert.equal(f.q.arrivalPending,true);assert.equal(f.s.positionReads,0);
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);f.s.physics=f.s.entity=f.q.arrivalDestination;f.s.time+=.02;f.tick();
  assert.equal(f.q.arrivalUnconfirmed,false);assert.deepEqual(nativeEffects(f),effects);
}
// Undefined/None Position is separately mocked, not inferred from the live
// zero-elapsed failure. Defined wrong types and invalid coordinates stay fatal.
for(const missing of ['undefined','None']){
  const f=queueReturn(),effects=nativeEffects(f);f.s.time+=.02;
  if(missing==='undefined')f.s.undefinedPosition=true;else f.s.type='None';
  const entityReads=f.s.entityReads;f.tick();assert.equal(f.q.arrivalPending,true);assert.equal(f.s.positionReads,1);
  assert.equal(f.q.arrivalObservationWait,'position-unavailable');
  assert.equal(f.s.entityReads,entityReads);assert.equal(f.q.arrivalObservationValid,false);
  f.s.undefinedPosition=false;f.s.type='Vector4';f.s.physics=f.s.entity=f.q.arrivalDestination;f.s.time+=.02;f.tick();
  assert.equal(f.q.arrivalUnconfirmed,false);assert.equal(f.q.active,false);assert.deepEqual(nativeEffects(f),effects);
}
for(const missing of ['state','capture','None'])for(const limit of ['time','callbacks']){
  const f=queueReturn(),effects=nativeEffects(f);
  if(missing==='state')f.s.current=false;if(missing==='capture')f.q.capturedInterface=null;if(missing==='None')f.s.type='None';
  f.s.time+=.001;f.tick(.001);
  const wait=missing==='None'?'position-unavailable':'context-or-capture';assert.equal(f.q.arrivalObservationWait,wait);
  if(limit==='time'){f.s.time=f.q.arrivalIssuedAt+.5;f.tick();}else for(let i=1;i<64;i++){f.s.time+=.001;f.tick(.001);}
  assert.equal(f.q.arrivalPending,false);assert.equal(f.q.arrivalUnconfirmed,true);assert.match(f.q.arrivalFailureReason,/limit/);
  assert.equal(f.q.arrivalObservationWait,wait,'timeout retains the last bounded wait cause');
  const readsAtReport=observationReads(f),report=f.p.NCCFlightProbeStopHere();assert(report.includes('observationWait='+wait));
  assert.deepEqual(observationReads(f),readsAtReport,'stored wait report adds no queries');
  const reads=f.s.positionReads;f.s.current=true;f.s.type='Vector4';f.q.capturedInterface=f.si;
  f.s.physics=f.s.entity=f.q.arrivalDestination;f.s.time+=.02;f.tick();
  assert.equal(f.s.positionReads,reads,'bounded timeout stops all later observation');assert.deepEqual(nativeEffects(f),effects);
}
for(const stale of ['interface','owner','state']){
  const f=fixture().active();f.s.accepted=false;queueReturn(f);let si=f.si;
  if(stale==='interface')si={...f.si};if(stale==='owner')si={...f.si,owner:{}};if(stale==='state')f.s.current=false;
  const effects=nativeEffects(f),reads=f.s.positionReads;f.p.NCCFlightProbeArrivalTick(.02,f.sc,si,'stand','Locomotion');
  assert.deepEqual(nativeEffects(f),effects,'stale cleanup cannot write original baseline');assert.equal(f.s.positionReads,reads);
}
for(const arrival of ['sameTime','physicsOnly','entityOnly','wrongDestination','blocked']){
  const f=queueReturn(),dest=f.q.arrivalDestination,effects=nativeEffects(f);
  if(arrival!=='sameTime')f.s.time+=.02;
  if(arrival==='physicsOnly')f.s.physics=dest;
  if(arrival==='entityOnly')f.s.entity=dest;
  if(arrival==='sameTime'||arrival==='blocked')f.s.entity=f.s.physics=dest;
  if(arrival==='blocked')f.s.clear=()=>false;
  f.tick();assert.equal(f.q.arrivalPending,true,arrival);assert.equal(f.q.arrivalUnconfirmed,true);assert.equal(f.q.active,false);
  assert.deepEqual(nativeEffects(f),effects);
  if(arrival==='sameTime')assert.equal(f.s.positionReads,0,'no native arrival read on the issuing simulation time');
}
for(const invalid of ['regression','NaN','Infinity','dt','W','type']){
  const f=queueReturn();f.s.time+=.02;
  if(invalid==='regression')f.s.time=f.q.arrivalIssuedAt-.1;if(invalid==='NaN')f.s.time=NaN;if(invalid==='Infinity')f.s.time=Infinity;
  if(invalid==='W')f.s.physics=new Vector4(0,0,0,0);if(invalid==='type')f.s.type='Vector3';
  f.tick(invalid==='dt'?NaN:.02);assert.equal(f.q.arrivalPending,false,invalid);assert.equal(f.q.arrivalUnconfirmed,true);
  const reads=f.s.positionReads;f.tick();assert.equal(f.s.positionReads,reads,'refusal stops observation until an explicit recheck');
}
for(const limit of ['time','callbacks'])for(const guard of ['readback','origin']){
  const f=queueReturn();if(limit==='time'){f.s.time+=.5;f.tick();}else for(let i=0;i<64;i++)f.tick(0);
  assert.equal(f.q.arrivalPending,false);assert.equal(f.q.arrivalUnconfirmed,true);assert.match(f.q.status,/limit/);
  const effects=nativeEffects(f),reads=f.s.positionReads;f.s.time+=.02;f.s.physics=f.s.entity=f.q.arrivalDestination;f.tick();
  assert.equal(f.s.positionReads,reads,'timed-out wait has no idle reads');assert.deepEqual(nativeEffects(f),effects);
  assert.match(f.start(),/Read-only arrival recheck/);assert.equal(f.q.preparePending,false);assert.equal(f.q.requested,false);
  assert.match(f.start(),/awaiting the queued/,'a second pending click cannot reset the recheck budget');f.tick();
  assert.equal(f.q.arrivalUnconfirmed,false);assert.equal(f.q.active,false);assert.equal(f.q.requested,false);assert.deepEqual(nativeEffects(f),effects);
  assert.match(f.start(),/Requested/);f.tick();f.tick();assert.equal(f.q.active,true);assert.equal(f.s.teleports.length,1);
  if(guard==='readback'){
    f.q.positionReadbackPending=true;f.q.positionLastTarget=new Vector4(f.s.physics.X+1.1,f.s.physics.Y,f.s.physics.Z,1);
  }else f.s.physics=new Vector4(f.s.entity.X+.3,f.s.entity.Y,f.s.entity.Z,1);
  f.tick();assert.equal(f.q.positionRefusals,1,'ordinary '+guard+' guard remains enforced after recheck and new Start');
  assert.match(f.q.positionLastRefusal,guard==='readback'?/more than 1m/:/origins diverged/);
}
for(const distance of [0,.01,.1,.24]){
  const f=fixture().active();f.q.start=new Vector4(f.s.entity.X+distance,f.s.entity.Y,f.s.entity.Z,1);
  f.s.deferTeleport=true;f.p.NCCFlightProbeReturn();f.tick();
  if(distance===0){assert.equal(f.s.teleports.length,0);assert.equal(f.q.active,false);assert.equal(f.q.arrivalUnconfirmed,false);continue;}
  assert.equal(f.s.teleports.length,1);assert(f.q.arrivalTolerance<distance);
  f.s.time+=.02;f.tick();assert.equal(f.q.arrivalUnconfirmed,true,'unchanged near-destination submission cannot acknowledge queued arrival');
  f.s.physics=f.s.entity=f.q.arrivalDestination;f.s.time+=.02;f.tick();assert.equal(f.q.arrivalUnconfirmed,false);
}
for(const method of ['EnterCondition','ToSprint','ToCrouchSprint']){
  for(const mode of ['active','paused','cleanup']){
    const f=fixture().active();f.q.paused=mode==='paused';if(mode==='cleanup'){f.q.restoreUnconfirmed=true;f.q.requested=false;}
    assert.deepEqual(dodgeDecision(f,f.si,'Locomotion',true,method),{result:false,calls:0},method+' '+mode);
  }
  for(const mode of ['idle','preparing','pending','foreignInterface','foreignOwner','foreignPlayer','missingInterface','otherMachine','stopped','returned']){
    const f=fixture();let si=f.si,machine='Locomotion';
    if(mode==='preparing')f.q.preparePending=f.q.requested=true;if(mode==='pending')f.q.transitionPending=true;
    if(mode==='foreignInterface'){f.q.active=true;si={...f.si};}if(mode==='foreignOwner'){f.q.active=true;si={...f.si,owner:{}};}
    if(mode==='foreignPlayer'){f.q.active=true;si={...f.si,owner:fixture().p};}if(mode==='missingInterface'){f.q.active=true;si=null;}
    if(mode==='otherMachine'){f.q.active=true;machine='LocomotionLowGravity';}
    if(mode==='stopped'||mode==='returned'){f.active();f.p[mode==='stopped'?'NCCFlightProbeStopHere':'NCCFlightProbeReturn']();f.tick();}
    for(const result of [true,false])assert.deepEqual(dodgeDecision(f,si,machine,result,method),{result,calls:1},method+' '+mode);
  }
}
const interactionKinds=['zoom','device','workspotBB','workspot'];
for(const kind of interactionKinds)for(const flow of ['update','paused','exit','forcedExit','return','restoreAt']){
  const f=fixture().active();f.s[kind]=kind==='workspotBB'?1:true;f.s.clear=()=>false;
  f.s.physics=new Vector4(30,20,30,1); // Even inconsistent/blocked placement must never trigger relocation during yield.
  if(flow==='paused')f.q.paused=true;
  if(flow==='exit')f.exit();else if(flow==='forcedExit')f.forcedExit();
  else if(flow==='restoreAt')f.p.NCCFlightProbeRestoreAt(f.si,f.q.start,{Yaw:0,Pitch:0,Roll:0},true,'return');
  else {if(flow==='return')f.p.NCCFlightProbeReturn();f.tick();}
  assert.equal(f.q.interactionYield,true,kind+' '+flow);assert.equal(f.q.active,false);assert.equal(f.q.requested,false);
  assert.equal(f.q.transitionPending,false);assert.equal(f.q.exitRequest,0);assert.equal(f.q.arrivalUnconfirmed,false);
  assert.equal(f.s.restores,1);assert.equal(f.s.teleports.length,0);assert.equal(f.s.zero,0);assert.equal(f.s.positions,0);
  assert.equal(f.s.velocity,0,'interaction yield only restores the owned normal filter');assert.equal(f.s.queries.length,0);
  assert.equal(f.s.positionReads,0);assert.equal(f.s.entityReads,0);assert.equal(f.q.restoreUnconfirmed,false);
  assert.match(f.p.NCCFlightProbeResume(packet()),/finish the interaction/);assert.match(f.p.NCCFlightProbeReturn(),/no relocation/);
  const reads={i:f.s.interactionReads,w:f.s.workspotReads,input:f.s.reads},status=f.q.status;
  for(let i=0;i<3;i++)f.tick();assert.deepEqual({i:f.s.interactionReads,w:f.s.workspotReads,input:f.s.reads},reads);
  assert.equal(f.q.status,status,'completed interaction yield keeps the idle fast path');
  assert.match(f.start(),/finish the device/);f.s[kind]=kind==='workspotBB'?0:false;f.s.physics=f.s.entity;f.s.clear=()=>true;
  assert.match(f.start(),/Requested/);assert.equal(f.q.interactionYield,false);f.tick();f.tick();assert.equal(f.q.active,true);
}
for(const kind of interactionKinds)for(const phase of ['beforeStart','preparing','prepared','capture']){
  const f=fixture();
  if(phase!=='beforeStart')f.start();if(phase==='prepared')f.tick();
  if(phase==='capture')f.s.afterCapture=()=>{f.s[kind]=kind==='workspotBB'?1:true;};else f.s[kind]=kind==='workspotBB'?1:true;
  if(phase==='beforeStart')assert.match(f.start(),/finish the device/);else {f.tick();if(phase==='capture')f.tick();}
  assert.equal(f.q.requested,false);assert.equal(f.q.active,false);assert.equal(f.s.zero,0);assert.equal(f.s.positions,0);
  assert.equal(f.s.restores,0,'preparation without flight ownership never writes a restoration filter');assert.equal(f.s.teleports.length,0);
}
{
  const f=fixture().active(),baseline=f.q.baselineFilter;f.s.zoom=true;f.s.accepted=false;f.tick();
  assert.equal(f.q.interactionYield,true);assert.equal(f.q.active,true);assert.equal(f.q.restoreUnconfirmed,true);
  f.s.zoom=false;f.q.baselineFilter={valid:true,replaced:true};f.s.physics=new Vector4(12,20,30,1);
  for(let i=0;i<3;i++){f.tick();f.p.NCCFlightProbeRestore(f.si,'forced state exit',true);}
  assert.equal(f.s.teleports.length,0);assert.equal(f.s.zero,0);assert.equal(f.s.positions,0);assert.equal(f.s.queries.length,0);
  for(const call of f.s.restoreArgs){assert.equal(call.si,f.si);assert.equal(call.v,baseline);}
  f.s.accepted=true;f.tick();assert.equal(f.q.active,false);assert.equal(f.q.restoreUnconfirmed,false);assert.equal(f.q.interactionYield,true);
}
for(const normal of [true,false]){
  const f=fixture().active();f.s.device=true;f.s.accepted=false;f.tick();const restores=f.s.restores;
  f.s.device=false;f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true,zero:!normal},normal);f.tick();
  assert.equal(f.s.restores,restores,'new original engine state supersedes old interaction cleanup authority');
  assert.equal(f.q.active,false);assert.equal(f.q.interfaceRef,null);assert.equal(f.q.restoreUnconfirmed,!normal);
  assert.equal(f.s.teleports.length,0);assert.equal(f.q.interactionYield,true);
  if(!normal){assert.match(f.start(),/restoration is unconfirmed/);f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);assert.equal(f.q.restoreUnconfirmed,false);}
}
for(const stale of ['interface','owner','executionOwner']){
  const f=fixture().active();f.s.workspot=true;f.s.accepted=false;f.tick();const effects=nativeEffects(f),reads=f.s.workspotReads;
  let si={...f.si};if(stale==='owner')si.owner={};if(stale==='executionOwner'){si=f.si;si.executionOwner={};}
  f.p.NCCFlightProbeCheckInteraction(si);assert.deepEqual(nativeEffects(f),effects);assert.equal(f.s.workspotReads,reads);
  assert.equal(f.q.restoreUnconfirmed,true);assert.equal(f.q.active,false);assert.equal(f.q.interactionYield,true);
  const captured=f.q.capturedFilter;f.p.NCCFlightProbeCaptureFilter({...f.si,executionOwner:{}},{valid:true},true);
  assert.equal(f.q.restoreUnconfirmed,true);assert.equal(f.q.capturedFilter,captured,'foreign execution owner cannot acknowledge cleanup');
}
for(const stage of ['command','preparation','active'])for(const missing of ['board','workspots','executionOwner']){
  const f=fixture();if(stage==='preparation')f.start();if(stage==='active')f.active();
  if(stage==='command')f.s.missingInteractionBoard=true;
  else if(missing==='board')f.si.localBlackboard=null;
  else if(missing==='workspots')f.si.GetWorkspotSystem=()=>null;
  else f.si.executionOwner={};
  if(stage==='command')assert.match(f.start(),/interaction state is unavailable/);else f.tick();
  assert.equal(f.q.requested,false);assert.equal(f.q.active,false);assert.equal(f.s.zero,0);assert.equal(f.s.positions,0);assert.equal(f.s.teleports.length,0);
}
{
  const f=fixture();for(let i=0;i<3;i++){f.tick();f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);}
  assert.equal(f.s.interactionReads,0);assert.equal(f.s.workspotReads,0);assert.equal(f.s.reads,0,'ordinary idle hooks perform no new polling');
  f.active();f.s.menu=true;f.p.NCCFlightProbeMenuChanged(true);f.tick();assert.equal(f.q.paused,true);assert.equal(f.q.active,true);
  assert.equal(f.q.interactionYield,undefined,'ordinary inventory menu retains existing pause behavior');assert.equal(f.s.restores,0);
}
{
  const f=queueReturn(),destination=f.q.arrivalDestination,serial=f.q.arrivalSerial;f.s.zoom=true;f.s.workspot=true;
  const effects=nativeEffects(f);f.p.NCCFlightProbeMenuChanged(true);f.start();f.p.NCCFlightProbeReturn();f.p.NCCFlightProbeStopHere();
  f.p.NCCFlightProbeResume(packet());f.p.NCCFlightProbeRestore(f.si,'interaction',true);f.tick();
  assert.equal(f.q.arrivalUnconfirmed,true);assert.equal(f.q.arrivalPending,true);assert.equal(f.q.arrivalDestination,destination);
  assert.equal(f.q.arrivalSerial,serial);assert.deepEqual(nativeEffects(f),effects);assert.equal(f.q.interactionYield,undefined);
}
function storedSubmission(q){return JSON.stringify({serial:q.arrivalSerial,cause:q.arrivalReason,control:q.arrivalControl,
  queued:q.arrivalExitIntent,processing:q.arrivalProcessingExitIntent,state:q.arrivalRestoreState,machine:q.arrivalRestoreMachine,
  destination:q.arrivalDestination,submitted:q.arrivalSubmittedPosition,issued:q.arrivalIssuedAt,capture:q.arrivalRestoreCapture,
  flags:q.arrivalInteractionFlags,target:q.arrivalPreviousTarget});}
function observationReads(f){return {input:f.s.reads,physics:f.s.positionReads,entity:f.s.entityReads,interaction:f.s.interactionReads,workspot:f.s.workspotReads};}
{
  const f=queueReturn(),submission=storedSubmission(f.q),effects=nativeEffects(f),reads=observationReads(f);
  assert.equal(f.q.arrivalControl,'return');assert.equal(f.q.arrivalExitIntent,0);assert.equal(f.q.arrivalProcessingExitIntent,2);
  assert.equal(f.q.processingExitRequest,0,'processing marker is cleared without changing exit handling');
  for(const command of [()=>f.start(),()=>f.p.NCCFlightProbeStopHere(),()=>f.p.NCCFlightProbeReturn(),()=>f.p.NCCFlightProbeResume(packet())]){
    const result=command();assert.match(result,/\[Stored relocation\]/);assert.match(result,/cause=Return requested/);
    assert.match(result,/control=return queuedExit=0 processingExit=2/);assert.match(result,/lastOwnedState=Locomotion\/stand/);
    assert.match(result,/lastValidObservation=false/);assert(result.length<=4096);
    assert.equal(storedSubmission(f.q),submission);assert.deepEqual(nativeEffects(f),effects);assert.deepEqual(observationReads(f),reads);
  }
  f.q.arrivalOwner={};assert.equal(f.p.NCCFlightProbeStoredArrivalReport('refused'),'refused','a different owner cannot expose stored relocation data');
  assert.deepEqual(observationReads(f),reads);
}
{
  const f=fixture().active();f.s.deferTeleport=true;f.s.clear=pos=>pos.X!==10;f.p.NCCFlightProbeStopHere();f.exit();
  assert.equal(f.q.arrivalControl,'stop-here');assert.equal(f.q.arrivalExitIntent,1);assert.equal(f.q.arrivalProcessingExitIntent,0);
  const report=f.start();assert.match(report,/cause=Restored normal collision for locomotion exit; recovery requested/);
  assert.match(report,/control=stop-here queuedExit=1 processingExit=0/,'outgoing exit before Stop processing retains pending command intent');
}
{
  const f=fixture().active();f.s.deferTeleport=true;f.q.positionReadbackPending=true;f.q.positionLastTarget=new Vector4(7,20,30,1);
  f.p.NCCFlightProbeStopHere();f.tick();assert.equal(f.q.positionRefusals,1);
  assert.equal(f.q.arrivalControl,'stop-here');assert.equal(f.q.arrivalExitIntent,0);assert.equal(f.q.arrivalProcessingExitIntent,0);
  assert.equal(f.q.arrivalPreviousReadbackPending,true);assert.equal(f.q.arrivalPreviousReadbackDistance,3);
  const report=f.p.NCCFlightProbeStopHere();assert.match(report,/cause=Position refused: prior target is more than 1m/);
  assert.match(report,/control=stop-here queuedExit=0 processingExit=0/,'blocked Stop followed by guard failure is distinct from outgoing exit');
}
{
  const f=queueReturn();f.s.time+=.02;f.s.type='Vector3';f.tick();
  const failure=f.q.arrivalFailureReason,callbacks=f.q.arrivalFailureCallbacks,elapsed=f.q.arrivalFailureElapsed;
  assert.match(failure,/invalid physics position type/);f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true},true);
  assert.doesNotMatch(f.q.status,/invalid physics position type/,'normal capture may replace human status');
  const report=f.start();assert.match(report,/Read-only arrival recheck requested/);assert.match(report,/latestFailure=.*invalid physics position type/);
  assert.equal(f.q.arrivalFailureReason,failure);assert.equal(f.q.arrivalFailureCallbacks,callbacks);assert.equal(f.q.arrivalFailureElapsed,elapsed);
  assert.equal(f.q.arrivalCallbacks,0);assert.equal(f.q.arrivalElapsed,0);assert.equal(f.q.active,false);assert.equal(f.q.requested,false);
}
{
  const f=queueReturn();f.s.time+=.02;f.s.physics=f.s.entity=new Vector4(1,2,3,1);f.tick();
  assert.equal(f.q.arrivalObservationValid,true);assert.equal(f.q.arrivalObservedAt,f.s.time);assert.equal(f.q.arrivalObservedState,'stand');
  const effects=nativeEffects(f),reads=observationReads(f),submission=storedSubmission(f.q),report=f.p.NCCFlightProbeStoredArrivalReport('refused');
  assert.match(report,/entity=1\.0000,2\.0000,3\.0000 physics=1\.0000,2\.0000,3\.0000/);
  assert.equal(storedSubmission(f.q),submission);assert.deepEqual(nativeEffects(f),effects);assert.deepEqual(observationReads(f),reads);
  f.q.arrivalReason='x'.repeat(20000);f.q.arrivalFailureReason='y'.repeat(20000);f.q.arrivalRestoreState='z'.repeat(20000);
  const bounded=f.p.NCCFlightProbeStoredArrivalReport('m'.repeat(20000));assert(bounded.length<=4096);
  assert(!bounded.includes('x'.repeat(257)));assert(!bounded.includes('y'.repeat(257)));assert(!bounded.includes('z'.repeat(65)));
}
{
  const f=fixture();const normal=f.start();assert(!normal.includes('[Stored relocation]'));f.tick();f.tick();
  const formats=f.s.formats;f.tick();assert.equal(f.s.formats,formats,'normal frames never format the new stored report');
}
console.log('PASS actual flight lifecycle and bounded command-time relocation evidence, preserving immutable cause/intent, retained failure, native behavior and idle fast paths');
