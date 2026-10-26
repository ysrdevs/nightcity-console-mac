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
    .replace(/let (\w+): [^;]+;/g,'let $1;').replace(/([\w.]+) \/ (\d+)u/g,'Math.floor($1 / $2)')
    .replace(/\b(\d+)u\b/g,'$1').replace(/\bn"/g,'"').replace(/\s+as PlayerPuppet/g,'')
    .replace(/FromVariant<Vector4>/g,'FromVariant')
    .replaceAll('probe.target + probe.positionOriginDelta','Vector4.Add(probe.target,probe.positionOriginDelta)')
    .replaceAll('physicsPosition - entityPosition','Vector4.Sub(physicsPosition,entityPosition)')
    .replaceAll('originDelta - probe.positionOriginDelta','Vector4.Sub(originDelta,probe.positionOriginDelta)')
    .replace(/cameraRight \* horizontal\s*\+ cameraForward \* forward\s*\+ new Vector4\(0.0, 0.0, vertical, 0.0\)/g,
      'Vector4.Add(Vector4.Add(Vector4.Scale(cameraRight,horizontal),Vector4.Scale(cameraForward,forward)),new Vector4(0,0,vertical,0))')
    .replaceAll('movement * (speed * dt)','Vector4.Scale(movement,speed*dt)')
    .replaceAll('probe.target + step','Vector4.Add(probe.target,step)')
    .replaceAll('nextTarget + probe.positionOriginDelta','Vector4.Add(nextTarget,probe.positionOriginDelta)')
    .replace(/\bif\s+([^{}]+)\{/g,'if ($1) {');
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
  Count:'value',BoundedVector:'value,limit',Allowed:'stateName,machineName',Toggle:'',Prepare:'commandPacket',Return:'',
  StopHere:'',Resume:'commandPacket',Restore:'scriptInterface,reason,allowRecovery',
  RestoreAt:'scriptInterface,destination,facing,move,reason',ObserveExitPosition:'scriptInterface',ProcessExit:'scriptInterface',
  PositionRefused:'scriptInterface,reason',CaptureFilter:'scriptInterface,value',SuspendForTransition:'scriptInterface',
  ExpireTransition:'expected,serial',ObserveStateFilter:'scriptInterface,stateName,machineName,capturedFresh',
  PreparationTick:'timeDelta,stateContext,scriptInterface,stateName,machineName',
  PreparationComplete:'stateContext,scriptInterface,stateName,machineName,capsuleHeight,capsuleRadius',
  Update:'timeDelta,stateContext,scriptInterface,stateName,machineName'};
const packet=(epoch=3,flags=512)=>epoch*65536+flags;
function fixture(){
  const s={menu:false,current:true,grounded:true,packet:packet(),time:100,entity:new Vector4(10,20,30,1),physics:new Vector4(10,20,30,1),
    reads:0,normal:0,zero:0,restores:0,velocity:0,positions:0,teleports:[],queries:[],callbacks:[],accepted:true,controls:true};
  const facing={Yaw:0,Pitch:0,Roll:0};
  const defaults=()=>({active:false,requested:false,paused:false,resumeRequested:false,exitRequest:0,preparePending:false,prepared:false,
    prepareCallbacks:0,prepareElapsed:0,transitionPending:false,transitionSerial:4,stopRequested:false,stopReason:'',restoreUnconfirmed:false,
    focusEpochValid:true,focusEpoch:3,lastInputPacket:packet(),inputChecks:0,captureWrites:0,baselineFilter:{valid:true},capturedFilter:{valid:true},
    ownFilterWrite:false,start:new Vector4(0,0,0,1),startFacing:facing,target:s.entity,lastClearValid:true,lastClearPosition:new Vector4(8,20,30,1),
    lastClearFacing:facing,lastClearanceProbePosition:s.entity,positionOriginDelta:new Vector4(),positionLastTarget:s.physics,positionReadbackPending:false,
    positionWritesIssued:0,positionReadbacks:0,positionRefusals:0,ticks:0,filterWrites:0,velocityWrites:0,maxObservedEntityRadius:0,
    maxPositionOriginDivergence:0,maxPositionReadbackDistance:0,elapsed:0,clearanceClock:0,clearanceProbes:0,capsuleHeight:1.8,capsuleRadius:.4});
  const p={nccCollisionFlightProbe:defaults(),GetGame:()=>0,IsDead:()=>!!s.dead,GetWorldPosition:()=>s.entity,GetWorldOrientation:()=>facing,
    NCCFlightProbeIsFilter:v=>!!v?.valid,NCCFlightProbeIsVelocity:()=>true,NCCFlightProbeZeroVelocity:()=>({}),
    NCCFlightProbeZeroFilter:()=>({valid:true,zero:true}),NCCFlightCameraBefore:()=>false,NCCFlightCameraStartActive:()=>{},
    NCCFlightProbeCameraFacing:()=>facing,NCCFlightInput(){s.reads++;return s.packet;},
    NCCFlightProbeWriteFilter(si,v){if(v.zero){s.zero++;if(s.afterZero)s.afterZero();return true;}s.restores++;return s.accepted;},
    NCCFlightClearanceInitialize(){s.initialized=true;return !s.initFails;},NCCFlightClearanceVerifyControls(si,pos){s.controlPosition=pos;return s.controls;},
    NCCFlightClearanceAt(si,pos){s.queries.push(pos);return s.clear?s.clear(pos):s.controls;}};
  const si={owner:p,IsMountedToObject:()=>!!s.mounted,IsPlayerInBraindance:()=>false,IsSceneAnimationActive:()=>false,IsOnGround:()=>s.grounded,
    SetStateVectorParameter(){s.velocity++;return true;},GetStateVectorParameter(k){return k==='pos'?{type:s.type||'Vector4',value:s.physics}:{type:'Vector4'};},
    GetCameraSystem:()=>({GetActiveCameraRight:()=>new Vector4(1,0,0,0),GetActiveCameraForward:()=>new Vector4(0,1,0,0)}),
    NCCFlightWritePosition(v){s.positions++;s.physics=new Vector4(v.X,v.Y,v.Z,1);s.entity=s.physics;return !s.rejectPosition;}};
  const board={GetBool:()=>s.menu,RegisterListenerBool(id,owner,callback){if(s.registrationFails)return null;owner[callback](s.menu);return {};}};
  const c=vm.createContext({Vector4,Vector3,FromVariant:v=>v.value,IsDefined:v=>v!==null&&v!==undefined,Equals:(a,b)=>a===b,NotEquals:(a,b)=>a!==b,
    AbsF:Math.abs,MinF:Math.min,MaxF:Math.max,ClampF:(n,a,b)=>Math.max(a,Math.min(n,b)),VariantTypeName:v=>v?.type||'physicsSimulationFilter',
    Quaternion:{ToEulerAngles:v=>v},GetAllBlackboardDefs:()=>({UI_System:{IsInMenu:'menu'}}),EngineTime:{ToFloat:v=>v},
    GameInstance:{GetBlackboardSystem:()=>({Get:()=>board}),GetSimTime:()=>s.time,GetDelaySystem:()=>({DelayCallbackNextFrame:cb=>s.callbacks.push(cb)}),
      GetTeleportationFacility:()=>({Teleport(owner,pos){assert.equal(owner,p);s.teleports.push(pos);s.entity=pos;s.physics=pos;}})},
    physicsStateValue:{Position:'pos',LinearVelocity:'vel'},NCCCollisionFlightTransitionWatchdog:class{},
    NCCCollisionFlightProbeState:class{constructor(){Object.assign(this,defaults(),{focusEpochValid:false});}},
    wrappedMethod:()=>{if(s.afterOriginal)s.afterOriginal();}});
  for(const [name,args]of Object.entries(methods))p['NCCFlightProbe'+name]=vm.runInContext(`(function(${args}){${body('NCCFlightProbe'+name)}})`,c).bind(p);
  const sc={IsStateActive:(m,n)=>s.current&&m==='Locomotion'&&n==='stand'};
  const transition={GetStateName:()=> 'stand',GetStateMachineName:()=> 'Locomotion',
    GetStaticBoolParameterDefault:()=>{s.static=(s.static||0)+1;return !!s.zeroPreset;},GetStaticFloatParameterDefault:(n,fallback)=>fallback,
    SetCollisionFilter(x){assert.equal(x,si);s.normal++;if(!s.captureFails)p.NCCFlightProbeCaptureFilter(si,{valid:true});if(s.afterCapture)s.afterCapture();}};
  const tick=vm.runInContext(`(function(timeDelta,stateContext,scriptInterface){${body('OnUpdate')}})`,c).bind(transition);
  p.nccCollisionFlightProbe.interfaceRef=si;p.nccCollisionFlightProbe.capturedInterface=si;
  return{s,p,si,sc,get q(){return p.nccCollisionFlightProbe;},tick(dt=.02,x=si){tick(dt,sc,x);},
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
  assert.equal(f.s.teleports[0],f.q.lastClearPosition);assert.equal(f.q.transitionPending,true);assert.equal(f.q.paused,true);const reads=f.s.reads;
  f.p.NCCFlightProbeObserveStateFilter(f.si,'stand','Locomotion',true);assert.equal(f.q.active,true);assert.equal(f.q.paused,true);assert.equal(f.s.reads,reads);
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
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true});assert.equal(f.q.restoreUnconfirmed,true);f.q.ownFilterWrite=false;
  f.p.NCCFlightProbeCaptureFilter(f.si,{valid:true});assert.equal(f.q.restoreUnconfirmed,false);
}
console.log('PASS actual travel lifecycle: setup, pause/resume/stop/return, unlimited bounded steps, current-state restoration, checkpoint recovery, cleanup retry, observed exit validation and idle/paused polling bounds');
