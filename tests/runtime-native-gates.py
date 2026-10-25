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
__attribute__((noinline,optnone,visibility("default"))) uintptr_t ncc_test_target(void* fn,void* ctx,void* depth) {
    uintptr_t n=(uintptr_t)depth;
    if(n) return ncc_test_target(fn,ctx,(void*)(n-1))+1;
    return 1;
}
__attribute__((visibility("default"))) uintptr_t ncc_test_call(uintptr_t fn,uintptr_t ctx,uintptr_t depth) {
    return ncc_test_target((void*)fn,(void*)ctx,(void*)depth);
}
__attribute__((noinline,optnone,visibility("default"))) void ncc_test_loc(void* out,uintptr_t key,void* unused,unsigned char* found) {
    *(uint32_t*)out=0; *found=0;
}
__attribute__((naked,visibility("default"))) void ncc_test_loc_call(void* out,uintptr_t key,void* unused,unsigned char* found) {
    __asm__("mov x8, x0\n b _ncc_test_loc\n");
}
static void* worker(void* opaque) {
    int n=*(int*)opaque; volatile uintptr_t sink=0;
    uintptr_t (*volatile target)(void*,void*,void*)=ncc_test_target;
    for(int i=0;i<n;i++)sink+=target((void*)0x1000,(void*)0x2000,0);
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
            if 'FAIL' in output or (mode == 'native' and ('PASS native executor gate:' not in output or 'PASS native localization gate:' not in output)):
                raise AssertionError(output)
            match = re.search(r'benchmark_calls=(\d+) elapsed_ms=([0-9.]+)', output)
            if not match:
                raise AssertionError(output)
            runs.append({'calls': int(match[1]), 'elapsed_ms': float(match[2])})
        results[mode] = {'runs': runs, 'median_ms': statistics.median(run['elapsed_ms'] for run in runs)}
    report = {'synthetic_not_game_fps': True, 'threads': 4,
              'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
              'gadget_sha256': hashlib.sha256(gadget.read_bytes()).hexdigest(),
              'checks': ['idle cache', 'context reuse after refresh', 'function discovery', 'recursive outermost dispatch', 'observer delivery',
                         'busy reentry', 'player changes', 'localization signed-range keys', 'ARM64 x8 output',
                         'found flag', 'nonmatching keys', 'key-table reload', 'empty key map'],
              'results': results}
    (directory / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if temporary:
        temporary.cleanup()


if __name__ == '__main__':
    main()
