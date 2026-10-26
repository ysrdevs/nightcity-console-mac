#!/usr/bin/env python3
"""Exercise production flight capture hooks in an isolated ARM64 Gadget host.

This never attaches to or launches the game. The native executor, original setter
and fake RTTI token model the verified ABI; they do not prove game behavior.
Production exports, capture storage and JavaScript CModule factories are extracted
from the working tree so this checks their actual integration, not a reimplementation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


HOST = r'''
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <thread>
#include <vector>

constexpr uintptr_t beginFn = 0xb1, endFn = 0xe1, wrapperFn = 0xabc;
constexpr uintptr_t originalReturn = 0xa1b2c3d4;
constexpr uint64_t beforeGuard = 0x1122334455667788, afterGuard = 0x99aabbccddeeff00;
alignas(8) static unsigned char fakeType[16];
struct Variant { uintptr_t type = 0; uint64_t payload[2]{}; };
static_assert(sizeof(Variant) == 24);
struct GuardedVariant { uint64_t before = beforeGuard; Variant value; uint64_t after = afterGuard; };
struct GuardedToken { uint32_t before = 0x11223344, value = 0xdeadbeef, after = 0xaabbccdd; };
struct Request { uint32_t mode, configured, nesting; uint64_t seed; };
enum Mode { Inline, Heap, WrongEnum, WrongType, Refused, WrongContext, OwnWrite,
            NestedSame, NestedOther, NullVariant };
struct ExpectedSetter {
    void* context = nullptr;
    uint32_t state = 0;
    const Variant* pointer = nullptr;
    Variant bytes;
    bool accepted = false;
};
static thread_local ExpectedSetter expected;
static thread_local uint32_t failures = 0;
static std::atomic<uint64_t> setterCalls{0}, beginCalls{0}, endCalls{0};

static uintptr_t typeToken() { return reinterpret_cast<uintptr_t>(fakeType); }
static bool guardsOK(const GuardedVariant& value) {
    return value.before == beforeGuard && value.after == afterGuard;
}
static void checkVariant(const Variant& value, bool captured, uint64_t seed) {
    const uintptr_t type = captured ? typeToken() | 1 : 0;
    const uint64_t a = captured ? seed ^ 0x123456789abcdef0 : 0;
    const uint64_t b = captured ? seed ^ 0xfedcba9876543210 : 0;
    if (value.type != type || value.payload[0] != a || value.payload[1] != b) failures |= 1;
}

extern "C" {
__attribute__((noinline,optnone,visibility("default"))) bool ncc_capture_setter(void* context, uint32_t state, const Variant* value) {
    setterCalls.fetch_add(1, std::memory_order_relaxed);
    if (context != expected.context || state != expected.state || value != expected.pointer)
        failures |= 2;
    if (value && std::memcmp(value, &expected.bytes, sizeof(Variant))) failures |= 4;
    return expected.accepted;
}
__attribute__((noinline,optnone,visibility("default"))) uintptr_t ncc_capture_executor(
    void* fn, void* context, void* frame, void* output, void* resultType);
}

static void invokeSetter(uint32_t mode, void* context, uint64_t seed) {
    uint64_t* heap = nullptr;
    Variant value{typeToken() | 1, {seed ^ 0x123456789abcdef0, seed ^ 0xfedcba9876543210}};
    if (mode == Heap) {
        heap = new uint64_t[2]{value.payload[0], value.payload[1]};
        value.type = typeToken();
        value.payload[0] = reinterpret_cast<uintptr_t>(heap);
        value.payload[1] = 0;
    }
    if (mode == WrongType) value.type = (typeToken() + 8) | 1;
    const uint32_t state = mode == WrongEnum ? 4 : 32;
    void* setterContext = mode == WrongContext ? reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(context) + 0x10) : context;
    const Variant* pointer = mode == NullVariant ? nullptr : &value;
    const bool accepted = mode != Refused;
    expected = {setterContext, state, pointer, value, accepted};
    if (ncc_capture_setter(setterContext, state, pointer) != accepted) failures |= 8;
    // The captured output must own its 16 bytes independently of both layouts.
    value = {};
    if (heap) { heap[0] = heap[1] = 0; delete[] heap; }
}

extern "C" {
__attribute__((noinline,optnone,visibility("default"))) uintptr_t ncc_capture_executor(
    void* fn, void* context, void* frame, void* output, void* resultType) {
    const auto function = reinterpret_cast<uintptr_t>(fn);
    if (function == beginFn) {
        beginCalls.fetch_add(1, std::memory_order_relaxed);
        if (output) *static_cast<uint32_t*>(output) = 0; // Actual redscript stub result.
    } else if (function == endFn) {
        endCalls.fetch_add(1, std::memory_order_relaxed);
        if (output) std::memset(output, 0, sizeof(Variant)); // Empty Variant stub.
    } else if (function == wrapperFn) {
        const auto request = *static_cast<const Request*>(frame);
        if (request.mode != OwnWrite) {
            GuardedToken token;
            if (ncc_capture_executor(reinterpret_cast<void*>(beginFn), context, nullptr, &token.value, nullptr) != originalReturn)
                failures |= 16;
            if (token.before != 0x11223344 || token.after != 0xaabbccdd ||
                bool(token.value) != bool(request.configured)) failures |= 32;
        }
        invokeSetter(request.mode, context, request.seed);
        if ((request.mode == NestedSame || request.mode == NestedOther) && request.nesting) {
            Request inner{request.mode, request.configured, request.nesting - 1, request.seed + 1};
            GuardedVariant nested;
            void* innerContext = request.mode == NestedOther
                ? reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(context) + 0x100) : context;
            if (ncc_capture_executor(reinterpret_cast<void*>(wrapperFn), innerContext, &inner, &nested.value, nullptr) != originalReturn)
                failures |= 64;
            if (!guardsOK(nested)) failures |= 128;
            checkVariant(nested.value, request.configured, inner.seed);
        }
        if (ncc_capture_executor(reinterpret_cast<void*>(endFn), context, nullptr, output, resultType) != originalReturn)
            failures |= 256;
    }
    return originalReturn;
}
__attribute__((visibility("default"))) void* ncc_capture_type() { return fakeType; }
__attribute__((visibility("default"))) uint64_t ncc_capture_setter_calls() { return setterCalls.load(); }
__attribute__((visibility("default"))) uint64_t ncc_capture_begin_calls() { return beginCalls.load(); }
__attribute__((visibility("default"))) uint64_t ncc_capture_end_calls() { return endCalls.load(); }
__attribute__((visibility("default"))) uint32_t ncc_capture_run(uint32_t mode, uint32_t configured,
    uint32_t nesting, uint64_t seed, void* output) {
    failures = 0;
    Request request{mode, configured, nesting, seed};
    GuardedVariant result;
    if (ncc_capture_executor(reinterpret_cast<void*>(wrapperFn), reinterpret_cast<void*>(0x2000),
        &request, &result.value, nullptr) != originalReturn) failures |= 512;
    if (!guardsOK(result)) failures |= 1024;
    const bool valid = configured && (mode == Inline || mode == Heap || mode == NestedSame || mode == NestedOther);
    checkVariant(result.value, valid, seed);
    if (output) std::memcpy(output, &result.value, sizeof(Variant));
    // A subsequent own write and unmatched End cannot reuse the earlier capture.
    invokeSetter(OwnWrite, reinterpret_cast<void*>(0x2000), seed + 100);
    GuardedVariant after;
    ncc_capture_executor(reinterpret_cast<void*>(endFn), reinterpret_cast<void*>(0x2000), nullptr, &after.value, nullptr);
    checkVariant(after.value, false, 0);
    if (!guardsOK(after)) failures |= 2048;
    return failures;
}
__attribute__((visibility("default"))) uint32_t ncc_capture_workers(uint32_t iterations) {
    std::atomic<uint32_t> problems{0};
    std::vector<std::thread> threads;
    for (uint32_t thread = 0; thread < 4; ++thread) threads.emplace_back([&, thread] {
        for (uint32_t i = 0; i < iterations; ++i) {
            const uint64_t seed = (uint64_t(thread) << 32) | i;
            for (uint32_t mode : {uint32_t(Inline), uint32_t(Heap), uint32_t(NestedSame), uint32_t(NestedOther), uint32_t(Refused)})
                problems.fetch_or(ncc_capture_run(mode, 1, 3, seed, nullptr));
        }
    });
    for (auto& thread : threads) thread.join();
    return problems.load();
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    void* gadget = dlopen(argv[1], RTLD_NOW);
    if (!gadget) { std::puts(dlerror()); return 2; }
    std::puts("host completed");
    return 0;
}
'''


TEST = r'''
try {
 const assert=(v,m)=>{if(!v)throw Error(m);};
 let entries=0,internalEntries=0,leaves=0;
 const gate=createExecutorGate((fn,ctx,frame)=>{
   entries++;
   if(fn.equals(ptr(0xb1))||fn.equals(ptr(0xe1)))internalEntries++;
   return 1;
 },()=>{leaves++;});
 globalThis.keepGate=gate;
 assert(gate.flightCaptureAvailable,'production capture exports available');
 gate.flightCaptureMethods(ptr(0xb1),ptr(0xe1));gate.observers(true);
 Interceptor.attach(Module.getGlobalExportByName('ncc_capture_executor'),gate.callbacks);
 Interceptor.flush();
 const native=(name,ret,args)=>new NativeFunction(Module.getGlobalExportByName(name),ret,args);
 const run=native('ncc_capture_run','uint',['uint','uint','uint','uint64','pointer']);
 const type=native('ncc_capture_type','pointer',[])();
 const setterCalls=native('ncc_capture_setter_calls','uint64',[]);
 const beginCalls=native('ncc_capture_begin_calls','uint64',[]);
 const endCalls=native('ncc_capture_end_calls','uint64',[]);
 const workers=native('ncc_capture_workers','uint',['uint']);
 const output=Memory.alloc(40);const result=output.add(8);
 const guarded=()=>{output.writeU64(uint64('0x1122334455667788'));output.add(32).writeU64(uint64('0x99aabbccddeeff00'));result.writeByteArray(new Uint8Array(24));};
 const checkGuards=()=>assert(output.readU64().equals(uint64('0x1122334455667788'))&&output.add(32).readU64().equals(uint64('0x99aabbccddeeff00')),'JS-side 24-byte result guards');
 guarded();let before=entries;
 assert(run(0,0,0,7,result)===0,'unconfigured Begin and End fail closed');
 assert(result.readPointer().isNull(),'unconfigured empty output');checkGuards();
 assert(entries===before+1&&internalEntries===0&&leaves===0,'Begin/End have no JavaScript callbacks before configuration');
 const hook=createFlightCaptureHook(Module.getGlobalExportByName('ncc_capture_setter'),type,16,8,32);
 globalThis.keepHook=hook;
 for(const mode of [0,1,2,3,4,5,6,7,8,9]) {
   guarded();before=entries;const nested=mode===7||mode===8;const seed=0x1234+mode;
   const callsBefore=setterCalls().toNumber();
   const resultCode=run(mode,1,nested?3:0,seed,result);
   assert(resultCode===0,'mode '+mode+' host checks 0x'+resultCode.toString(16));
   const valid=[0,1,7,8].includes(mode);
   assert(result.readPointer().equals(valid?type.or(1):ptr(0)),'mode '+mode+' exact inline type or empty');
   if(valid) {
     assert(result.add(8).readU64().equals(uint64('0x123456789abcdef0').xor(seed)),'first payload preserved independently');
     assert(result.add(16).readU64().equals(uint64('0xfedcba9876543210').xor(seed)),'second payload preserved independently');
   }
   checkGuards();
   assert(entries===before+(nested?4:1),'only natural wrapper dispatches enter JavaScript');
   assert(setterCalls().toNumber()===callsBefore+(nested?5:2),'every original setter executes exactly once');
   assert(internalEntries===0&&leaves===0,'Begin/End never enter JavaScript');
 }
 console.log('PASS native capture integration: unconfigured, inline and heap snapshots, exact 24-byte guards, original arguments/results, wrong enum/type/context/null, rejected original, own writes excluded, natural executor scopes and nested owners');
 gate.busy(true);before=entries;
 const concurrent=workers(100);
 assert(concurrent===0,'four-thread nested capture and result isolation: 0x'+concurrent.toString(16));
 assert(entries===before&&internalEntries===0&&leaves===0,'busy concurrent paths require no JavaScript callback');
 gate.busy(false);
 assert(beginCalls().toNumber()>0&&endCalls().toNumber()>beginCalls().toNumber(),'original script stubs remain executed');
 console.log('PASS native capture concurrency: four native threads, same interface identities, independent nesting and inline/heap lifetimes, no JavaScript capture callbacks; Frida '+Frida.version);
} catch(e) {console.log('FAIL '+e.stack);}
'''


def section(source, name):
    return source.split('// BEGIN ' + name, 1)[1].split('// END ' + name, 1)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gadget', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    header = root / 'overlay/flight_capture.h'
    if not header.is_file():
        parser.error('overlay/flight_capture.h must exist before this integration test runs')
    runtime = (root / 'runtime/red4ext_hooks.js').read_text()
    overlay = (root / 'overlay/overlay.mm').read_text()
    gate = section(runtime, 'NATIVE EXECUTOR GATE')
    exports = section(overlay, 'FLIGHT CAPTURE EXPORTS')
    atomics = section(overlay, 'RUNTIME ATOMIC HELPERS')
    temporary = tempfile.TemporaryDirectory(prefix='nightcity-flight-capture-') if args.output is None else None
    directory = args.output or Path(temporary.name)
    directory.mkdir(parents=True, exist_ok=True)
    gadget = directory / 'FridaGadget.dylib'
    if args.gadget.resolve() != gadget.resolve():
        shutil.copy2(args.gadget, gadget)
    (directory / 'FridaGadget.config').write_text(json.dumps({'interaction': {
        'type': 'script', 'path': str(directory / 'probe.js'), 'on_load': 'resume'}}))
    host = '#include "' + str(header) + '"\n' + atomics + exports + HOST
    (directory / 'host.cpp').write_text(host)
    (directory / 'probe.js').write_text(gate + TEST)
    subprocess.run(['clang++', '-std=c++17', '-O2', '-arch', 'arm64', '-Wl,-export_dynamic',
                    '-o', str(directory / 'host'), str(directory / 'host.cpp')], check=True)
    completed = subprocess.run([str(directory / 'host'), str(gadget)], capture_output=True,
                               text=True, timeout=60, check=True)
    output = completed.stdout + completed.stderr
    (directory / 'native-flight-capture.txt').write_text(output)
    required = ['PASS native capture integration:', 'PASS native capture concurrency:', 'host completed']
    if 'FAIL' in output or any(marker not in output for marker in required):
        raise AssertionError(output)
    report = {
        'isolated_host_not_game_acceptance': True,
        'runtime_sha256': hashlib.sha256(runtime.encode()).hexdigest(),
        'capture_header_sha256': hashlib.sha256(header.read_bytes()).hexdigest(),
        'capture_exports_sha256': hashlib.sha256(exports.encode()).hexdigest(),
        'gadget_sha256': hashlib.sha256(gadget.read_bytes()).hexdigest(),
        'threads': 4,
        'worker_iterations': 100,
        'checks': ['production exports and CModule factories', 'unconfigured fail closed',
                   'exact inline and heap source captures', 'owned payload after source lifetime',
                   '24-byte output guards and 4-byte Begin guards', 'original setter arguments and bool return unchanged',
                   'wrong enum, type, context and null rejected', 'false original result not captured',
                   'own writes outside capture ignored', 'natural Begin/setter/End executor route',
                   'Begin/End avoid JavaScript callbacks', 'nested same/different contexts',
                   'four-thread scope and result isolation', 'original Begin/End stub execution preserved'],
    }
    (directory / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(output, end='')
    print(json.dumps(report, indent=2))
    if temporary:
        temporary.cleanup()


if __name__ == '__main__':
    main()
