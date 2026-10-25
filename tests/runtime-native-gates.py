#!/usr/bin/env python3
"""Exercise actual native Frida filters in an isolated ARM64 process, never in the game.

Pass the existing shipped FridaGadget.dylib with --gadget. The host, library copy,
config and reports are confined to --output (or a temporary directory). The
four-thread timing comparison measures synthetic callback cost, not game FPS.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import tempfile

HOST = r'''
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#define FLIGHT_FN ((uintptr_t)0xf100)
#define FLIGHT_STUB ((uint32_t)256)
#define ORDINARY_RESULT ((uint32_t)0x13579bdf)
static uint32_t flight_packet=FLIGHT_STUB, flight_failures=0, flight_reads=0;
typedef struct { uint32_t before[2],value,after[2]; } FlightResult;
static FlightResult result_buffer(void) {
    return (FlightResult){{0x11223344,0x55667788},0xdeadbeef,{0x99aabbcc,0xddeeff00}};
}
static int result_ok(const FlightResult* r,uint32_t expected) {
    return r->before[0]==0x11223344 && r->before[1]==0x55667788 && r->value==expected &&
           r->after[0]==0x99aabbcc && r->after[1]==0xddeeff00;
}
#ifndef NCC_OMIT_FLIGHT_EXPORT
__attribute__((visibility("default"))) uint32_t nightcity_flight_input(void) {
    __atomic_fetch_add(&flight_reads,1,__ATOMIC_RELAXED);
    return __atomic_load_n(&flight_packet,__ATOMIC_ACQUIRE);
}
#endif
__attribute__((visibility("default"))) void ncc_test_set_flight_packet(uint32_t value) {
    __atomic_store_n(&flight_packet,value,__ATOMIC_RELEASE);
}
__attribute__((visibility("default"))) uint32_t ncc_test_flight_reads(void) {
    return __atomic_load_n(&flight_reads,__ATOMIC_RELAXED);
}
__attribute__((noinline,optnone,visibility("default"))) uintptr_t ncc_test_target(void* fn,void* ctx,void* depth,void* result,void* result_type) {
    uintptr_t n=(uintptr_t)depth;
    uintptr_t returned=1;
    if(n) {
        FlightResult nested=result_buffer();
        returned=ncc_test_target(fn,ctx,(void*)(n-1),&nested.value,result_type)+1;
        uint32_t expected=(uintptr_t)fn==FLIGHT_FN ? __atomic_load_n(&flight_packet,__ATOMIC_ACQUIRE) : ORDINARY_RESULT;
        if(!result_ok(&nested,expected)) __atomic_fetch_add(&flight_failures,1,__ATOMIC_RELAXED);
        if((uintptr_t)fn==FLIGHT_FN) {
            FlightResult ordinary=result_buffer();
            ncc_test_target((void*)0xd00d,ctx,NULL,&ordinary.value,result_type);
            if(!result_ok(&ordinary,ORDINARY_RESULT)) __atomic_fetch_add(&flight_failures,1,__ATOMIC_RELAXED);
        }
    }
    if(result) *(uint32_t*)result=(uintptr_t)fn==FLIGHT_FN ? FLIGHT_STUB : ORDINARY_RESULT;
    return returned;
}
__attribute__((visibility("default"))) uintptr_t ncc_test_call(uintptr_t fn,uintptr_t ctx,uintptr_t depth) {
    return ncc_test_target((void*)fn,(void*)ctx,(void*)depth,NULL,NULL);
}
__attribute__((visibility("default"))) uintptr_t ncc_test_exec_call(uintptr_t fn,uintptr_t ctx,uintptr_t depth,void* result) {
    return ncc_test_target((void*)fn,(void*)ctx,(void*)depth,result,(void*)0xf200);
}
static void* flight_worker(void* opaque) {
    int n=*(int*)opaque;
    for(int i=0;i<n;i++) {
        FlightResult output=result_buffer();
        uintptr_t depth=(uintptr_t)(i%4);
        uintptr_t returned=ncc_test_target((void*)FLIGHT_FN,(void*)0x2000,(void*)depth,&output.value,(void*)0xf200);
        if(returned!=depth+1 || !result_ok(&output,__atomic_load_n(&flight_packet,__ATOMIC_ACQUIRE)))
            __atomic_fetch_add(&flight_failures,1,__ATOMIC_RELAXED);
        FlightResult ordinary=result_buffer();
        ncc_test_target((void*)0xd00d,(void*)0x2000,0,&ordinary.value,(void*)0xf200);
        if(!result_ok(&ordinary,ORDINARY_RESULT)) __atomic_fetch_add(&flight_failures,1,__ATOMIC_RELAXED);
    }
    return NULL;
}
__attribute__((visibility("default"))) uint32_t ncc_test_flight_workers(int iterations) {
    __atomic_store_n(&flight_failures,0,__ATOMIC_RELAXED);
    pthread_t threads[4];
    for(int i=0;i<4;i++) if(pthread_create(&threads[i],NULL,flight_worker,&iterations)) return UINT32_MAX;
    for(int i=0;i<4;i++) if(pthread_join(threads[i],NULL)) return UINT32_MAX;
    return __atomic_load_n(&flight_failures,__ATOMIC_RELAXED);
}
__attribute__((noinline,optnone,visibility("default"))) void ncc_test_loc(void* out,uintptr_t key,void* unused,unsigned char* found) {
    *(uint32_t*)out=0; *found=0;
}
__attribute__((naked,visibility("default"))) void ncc_test_loc_call(void* out,uintptr_t key,void* unused,unsigned char* found) {
    __asm__("mov x8, x0\n b _ncc_test_loc\n");
}
static void* worker(void* opaque) {
    int n=*(int*)opaque; volatile uintptr_t sink=0;
    uintptr_t (*volatile target)(void*,void*,void*,void*,void*)=ncc_test_target;
    for(int i=0;i<n;i++)sink+=target((void*)0x1000,(void*)0x2000,0,NULL,NULL);
    return (void*)sink;
}
int main(int argc,char**argv) {
    if(argc<3)return 2;
    void* d=dlopen(argv[1],RTLD_NOW); if(!d){puts(dlerror()); return 2;}
    int n=atoi(argv[2]); pthread_t threads[4]; struct timespec a,b;
    clock_gettime(CLOCK_MONOTONIC,&a);
    for(int i=0;i<4;i++)pthread_create(&threads[i],NULL,worker,&n);
    for(int i=0;i<4;i++)pthread_join(threads[i],NULL);
    clock_gettime(CLOCK_MONOTONIC,&b);
    printf("benchmark_calls=%d elapsed_ms=%.3f\n",n*4,(b.tv_sec-a.tv_sec)*1000.0+(b.tv_nsec-a.tv_nsec)/1e6);
    return 0;
}
'''

UNIT_TEST = r'''
try {
 const assert=(v,m)=>{if(!v)throw Error(m);}; let captures=0,drains=[];
 const gate=createExecutorGate((fn,ctx,frame)=>{captures++; if(ctx.equals(ptr(0x3000))||ctx.equals(ptr(0x4000))){gate.player(ctx);return 2;}return 1;},(ctx,depth)=>{drains.push(depth); if(depth===0)gate.pending(false);});
 globalThis.keep=gate;
 Interceptor.attach(Module.getGlobalExportByName('ncc_test_target'),gate.callbacks);
 Interceptor.flush();
 const call=new NativeFunction(Module.getGlobalExportByName('ncc_test_call'),'uint64',['uint64','uint64','uint64']);
 call(0x1000,0x2000,0); let n=captures; assert(n===1,'first capture');
 call(0x1000,0x2000,0); assert(captures===n,'idle skips JS');
 call(0x1100,0x2000,0); assert(captures===n+1,'uncaptured function checked');
 gate.fromTdbid(); n=captures; call(0x1200,0x2000,0); assert(captures===n,'resolved FromTDBID skips method checks');
 gate.refresh(); call(0x1200,0x2000,0); assert(captures===n+1,'recycled contexts rediscovered after refresh');
 gate.pending(true); assert(call(0x1000,0x2000,3).toNumber()===4,'return preserved'); assert(drains.join(',')==='3,2,1,0','exact recursive depth: '+drains.join(','));
 n=captures; gate.observers(true); call(0x1000,0x2000,0); call(0x1000,0x2000,0); assert(captures===n+2,'observer sees known context each call'); gate.observers(false);
 gate.busy(true); gate.pending(true); n=captures; drains=[]; call(0x1000,0x2000,2); assert(captures===n && drains.length===0,'busy suppresses reentry'); gate.busy(false); gate.pending(false);
 call(0x1000,0x3000,0); n=captures; call(0x1000,0x3000,0); assert(captures===n,'same player skips');
 call(0x1000,0x4000,0); call(0x1000,0x3000,0); assert(captures===n+2,'player switches preserved');

 // The executor's fourth argument is a typed result pointer, not the ARM64 x8
 // struct-return channel used below by the unrelated localization fixture.
 const flightCall=new NativeFunction(Module.getGlobalExportByName('ncc_test_exec_call'),'uint64',['uint64','uint64','uint64','pointer']);
 const setPacket=new NativeFunction(Module.getGlobalExportByName('ncc_test_set_flight_packet'),'void',['uint']);
 const readCount=new NativeFunction(Module.getGlobalExportByName('ncc_test_flight_reads'),'uint',[]);
 const flightWorkers=new NativeFunction(Module.getGlobalExportByName('ncc_test_flight_workers'),'uint',['int']);
 const resultBuffer=()=>{const p=Memory.alloc(20);[0x11223344,0x55667788,0xdeadbeef,0x99aabbcc,0xddeeff00].forEach((v,i)=>p.add(i*4).writeU32(v));return p;};
 const checkResult=(p,value,label)=>{const expected=[0x11223344,0x55667788,value,0x99aabbcc,0xddeeff00];expected.forEach((v,i)=>assert(p.add(i*4).readU32()===v,label+' word '+i));};
 let guarded=resultBuffer(), reads=readCount();
 setPacket(512|1|16); flightCall(0xf100,0x2000,0,guarded.add(8));
 checkResult(guarded,256,'unconfigured stub remains blocked');assert(readCount()===reads,'unconfigured has no getter reads');
 gate.flightInput(ptr(0xf100));
 for(const packet of [256,512,512|256,512|1|16,512|2|4|8|32|64|128]) {
   setPacket(packet);guarded=resultBuffer();n=captures;reads=readCount();
   flightCall(0xf100,0x2000,0,guarded.add(8));
   checkResult(guarded,packet,'exact Uint32 packet '+packet);
   assert(captures===n,'flight path never enters JavaScript');assert(readCount()===reads+1,'one getter read per matching result');
 }
 guarded=resultBuffer();reads=readCount();flightCall(0xf101,0x2000,0,guarded.add(8));
 checkResult(guarded,0x13579bdf,'nearby function unchanged');assert(readCount()===reads,'nonmatch does not read getter');
 reads=readCount();flightCall(0xf100,0x2000,0,ptr(0));assert(readCount()===reads,'null output is ignored');
 setPacket(512|16);gate.busy(true);guarded=resultBuffer();n=captures;
 flightCall(0xf100,0x2000,0,guarded.add(8));checkResult(guarded,512|16,'busy commands preserve flight input');assert(captures===n,'busy flight still has no JavaScript');gate.busy(false);
 gate.observers(true);guarded=resultBuffer();n=captures;
 flightCall(0xf100,0x2000,0,guarded.add(8));checkResult(guarded,512|16,'internal input with observers');assert(captures===n,'internal flight method stays native with observers');gate.observers(false);
 guarded=resultBuffer();setPacket(512|1|64);assert(flightCall(0xf100,0x2000,3,guarded.add(8)).toNumber()===4,'nested executor return retained');
 checkResult(guarded,512|1|64,'outer nested result');
 assert(flightWorkers(250)===0,'four-thread nested and interleaved result buffers stay isolated');
 gate.pending(true);drains=[];guarded=resultBuffer();flightCall(0xf100,0x2000,0,guarded.add(8));
 assert(drains.join(',')==='0','flight return preserves outermost depth accounting');gate.pending(false);
 gate.flightInput(ptr(0));guarded=resultBuffer();reads=readCount();flightCall(0xf100,0x2000,0,guarded.add(8));
 checkResult(guarded,256,'removed binding fails closed');assert(readCount()===reads,'removed binding does no getter work');
 console.log('PASS native flight input gate: exact method, Uint32 guard bytes, unconfigured and removed binding, blocked/ready bits, null output, busy commands, nested and four-thread result isolation, depth accounting');

 const seen=[]; const locGate=createLocalizationGate({10:'low',2147483649:'high',4294967295:'max'},(out,key,found)=>{seen.push(key);out.writeU32(key);found.writeU8(1);});
 globalThis.keepLoc=locGate;
 Interceptor.attach(Module.getGlobalExportByName('ncc_test_loc'),locGate.callbacks);Interceptor.flush();
 const lookup=new NativeFunction(Module.getGlobalExportByName('ncc_test_loc_call'),'void',['pointer','uint64','pointer','pointer']);
 const out=Memory.alloc(4),found=Memory.alloc(1);
 for(const key of [10,2147483649,4294967295]){lookup(out,key,ptr(0),found);assert(out.readU32()===key&&found.readU8()===1,'matched localization output '+key);}
 let hits=seen.length;lookup(out,11,ptr(0),found);assert(seen.length===hits&&out.readU32()===0&&found.readU8()===0,'unmatched stays native');
 locGate.reload({11:'new'});lookup(out,10,ptr(0),found);assert(seen.length===hits,'removed key excluded');lookup(out,11,ptr(0),found);assert(seen.length===hits+1&&out.readU32()===11,'new key immediate');
 locGate.reload({});hits=seen.length;lookup(out,11,ptr(0),found);assert(seen.length===hits,'empty map skips JS');
 console.log('PASS native localization gate: low/high keys, exact x8 output, found flag, nonmatches, reload, empty map');
 console.log('PASS native executor gate: cache, function discovery, nesting, observers, reentry, player changes; Frida '+Frida.version);
} catch(e) { console.log('FAIL '+e.stack); }
'''

MISSING_FLIGHT_EXPORT_TEST = r'''
try {
 const assert=(v,m)=>{if(!v)throw Error(m);};let captures=0;
 assert(Module.findGlobalExportByName('nightcity_flight_input')===null,'fixture omits the native input export');
 const gate=createExecutorGate(()=>{captures++;return 1;},()=>{});globalThis.keep=gate;
 assert(gate.flightInputAvailable===false,'missing export is explicitly unavailable');
 gate.flightInput(ptr(0xf100));gate.fromTdbid();
 Interceptor.attach(Module.getGlobalExportByName('ncc_test_target'),gate.callbacks);Interceptor.flush();
 const call=new NativeFunction(Module.getGlobalExportByName('ncc_test_exec_call'),'uint64',['uint64','uint64','uint64','pointer']);
 const setPacket=new NativeFunction(Module.getGlobalExportByName('ncc_test_set_flight_packet'),'void',['uint']);
 const p=Memory.alloc(12);p.writeU32(0x11223344);p.add(4).writeU32(0xdeadbeef);p.add(8).writeU32(0x55667788);
 setPacket(512|1|16);call(0xf100,0x2000,0,p.add(4));
 assert(p.readU32()===0x11223344&&p.add(4).readU32()===256&&p.add(8).readU32()===0x55667788,'fallback remains blocked and writes only UInt32');
 assert(captures===0,'fallback getter remains native');
 call(0xf101,0x2000,0,p.add(4));assert(p.add(4).readU32()===0x13579bdf,'unrelated result remains original');
 console.log('PASS missing flight export: unavailable, blocked fallback, guarded UInt32 output, native path, unrelated result');
} catch(e) {console.log('FAIL '+e.stack);}
'''

LEGACY = r'''
const depth={}; Interceptor.attach(Module.getGlobalExportByName('ncc_test_target'),{
 onEnter:function(args){this.commandContext=args[1];const tid=this.threadId;depth[tid]=(depth[tid]||0)+1;},
 onLeave:function(){const tid=this.threadId,d=(depth[tid]||1)-1;if(d>0)depth[tid]=d;else delete depth[tid];this.commandContext=null;}
});Interceptor.flush();console.log('legacy JS entry/leave reference');
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gadget', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--iterations', type=int, default=10000)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100000:
        parser.error('--iterations must be 1..100000')
    source = (Path(__file__).resolve().parents[1] / 'runtime/red4ext_hooks.js').read_text()
    gates = '\n'.join(source.split('// BEGIN NATIVE ' + name + ' GATE')[1].split('// END NATIVE ' + name + ' GATE')[0]
                      for name in ['EXECUTOR', 'LOCALIZATION'])
    temporary = tempfile.TemporaryDirectory(prefix='nightcity-native-gates-') if args.output is None else None
    directory = args.output or Path(temporary.name)
    directory.mkdir(parents=True, exist_ok=True)
    gadget = directory / 'FridaGadget.dylib'
    if args.gadget.resolve() != gadget.resolve():
        shutil.copy2(args.gadget, gadget)
    (directory / 'FridaGadget.config').write_text(json.dumps({'interaction': {'type': 'script', 'path': str(directory / 'probe.js'), 'on_load': 'resume'}}))
    overlay = (Path(__file__).resolve().parents[1] / 'overlay/overlay.mm').read_text()
    atomics = overlay.split('// BEGIN RUNTIME ATOMIC HELPERS')[1].split('// END RUNTIME ATOMIC HELPERS')[0]
    (directory / 'host.c').write_text('#include <stdint.h>\n' + atomics + HOST)
    subprocess.run(['clang', '-O2', '-arch', 'arm64', '-Wl,-export_dynamic', '-o', str(directory / 'host'), str(directory / 'host.c')], check=True)
    results = {}
    for mode in ['unhooked', 'javascript', 'native']:
        script = gates + UNIT_TEST if mode == 'native' else LEGACY if mode == 'javascript' else "console.log('unhooked reference');"
        (directory / 'probe.js').write_text(script)
        runs = []
        for attempt in range(3):
            completed = subprocess.run([str(directory / 'host'), str(gadget), str(args.iterations)], capture_output=True, text=True, timeout=45, check=True)
            output = completed.stdout + completed.stderr
            (directory / f'{mode}-{attempt + 1}.txt').write_text(output)
            if 'FAIL' in output or (mode == 'native' and any(marker not in output for marker in
                    ['PASS native executor gate:', 'PASS native localization gate:', 'PASS native flight input gate:'])):
                raise AssertionError(output)
            match = re.search(r'benchmark_calls=(\d+) elapsed_ms=([0-9.]+)', output)
            if not match:
                raise AssertionError(output)
            runs.append({'calls': int(match[1]), 'elapsed_ms': float(match[2])})
        results[mode] = {'runs': runs, 'median_ms': statistics.median(run['elapsed_ms'] for run in runs)}
    # A real second host omits the optional export. Exercise the production
    # CModule fallback without mocking the loader or shipping any test symbol.
    fallback_host = directory / 'host-no-flight-export'
    subprocess.run(['clang', '-O2', '-arch', 'arm64', '-DNCC_OMIT_FLIGHT_EXPORT=1',
                    '-Wl,-export_dynamic', '-o', str(fallback_host), str(directory / 'host.c')], check=True)
    (directory / 'probe.js').write_text(gates + MISSING_FLIGHT_EXPORT_TEST)
    completed = subprocess.run([str(fallback_host), str(gadget), '1'], capture_output=True,
                               text=True, timeout=45, check=True)
    fallback_output = completed.stdout + completed.stderr
    (directory / 'native-no-flight-export.txt').write_text(fallback_output)
    if 'FAIL' in fallback_output or 'PASS missing flight export:' not in fallback_output:
        raise AssertionError(fallback_output)
    report = {'synthetic_not_game_fps': True, 'threads': 4,
              'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
              'gadget_sha256': hashlib.sha256(gadget.read_bytes()).hexdigest(),
              'checks': ['idle cache', 'context reuse after refresh', 'function discovery', 'recursive outermost dispatch', 'observer delivery',
                         'busy reentry', 'player changes', 'localization signed-range keys', 'ARM64 x8 output',
                         'found flag', 'nonmatching keys', 'key-table reload', 'empty key map',
                         'flight exact method and fourth-argument Uint32 result', 'flight output guard bytes',
                         'flight blocked and ready packets', 'flight unconfigured and removed binding',
                         'flight null output', 'flight busy reentry', 'flight nested and four-thread result isolation',
                         'flight outermost depth accounting', 'flight internal method with observers',
                         'flight missing-export native blocked fallback'],
              'results': results}
    (directory / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if temporary:
        temporary.cleanup()


if __name__ == '__main__':
    main()
