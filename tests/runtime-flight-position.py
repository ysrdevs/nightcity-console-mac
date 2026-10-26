#!/usr/bin/env python3
"""Exercise the production position bridge in an isolated ARM64 Gadget host.

This never launches or attaches to the game. It extracts the real overlay exports,
raw X8 getter adapter and runtime CModule factories. Its fake engine verifies ABI,
ownership and call ordering, not whether a game character actually moves.
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

constexpr uintptr_t writerFn = 0xc1, unrelatedFn = 0xc2;
constexpr uintptr_t originalReturn = 0xa1b2c3d4;
constexpr uint32_t validHandle = 0xabc00042, changedHandle = 0xabc00043;
alignas(8) static unsigned char fakeType[16], fakeFilterType[16];
struct Variant { uintptr_t type = 0; uint64_t payload[2]{}; };
static_assert(sizeof(Variant) == 24);
struct alignas(8) Interface { unsigned char bytes[0xb0]; };
struct GuardedBool { uint32_t before = 0x11223344; uint8_t value = 0xcc; uint8_t after[7]{1,2,3,4,5,6,7}; };
struct GuardedXYZ { uint64_t before = 0x1122334455667788; float xyz[3]{}; uint32_t after = 0xaabbccdd; uint64_t last = 0x99aabbccddeeff00; };
enum Mode { Inline, Heap, WrongEnum, WrongType, NullVariant, NullPayload, WrongContext,
    OriginalTrue, TargetNaN, TargetInfinity, TooFar, InvalidHandle, ChangedByOriginal,
    ChangedByGetter, InvalidCurrent, InitFailure, WriteFailure, Duplicate, NestedSame,
    NestedOther, RejectedThenValid, Outside, WrongMethod, NullOutput, EmptyWriter,
    TargetWorldRange, GetterNoOutput, ExactBoundary, DiagonalTooFar, GetterReentry };
struct Request { uint32_t mode, configured; };
struct ExpectedSetter { void* context; uint32_t state; const Variant* pointer; Variant bytes; bool accepted; };
struct ExpectedExecutor { void* fn; void* context; void* frame; void* output; void* type; };
struct LocalState {
    Interface interface{}, other{};
    uint32_t mode = 0, configured = 0, failures = 0;
    uint32_t setters = 0, getters = 0, inits = 0, writes = 0, commits = 0, destroys = 0;
    uint32_t eventsLength = 0;
    char events[256]{};
    float current[3]{100.0f, -200.0f, 300.0f};
    float target[3]{100.25f, -200.5f, 300.125f};
    void* builder = nullptr;
    bool adapterOnly = false;
    ExpectedSetter setter{};
    ExpectedExecutor executor{};
};
static thread_local LocalState state;
static std::atomic<uint64_t> allSetters{0}, allWriters{0}, allCommits{0};
static uintptr_t typeToken() { return reinterpret_cast<uintptr_t>(fakeType); }
static void event(char value) {
    if (state.eventsLength + 1 >= sizeof(state.events)) { state.failures |= 1; return; }
    state.events[state.eventsLength++] = value; state.events[state.eventsLength] = 0;
}
static void check(bool value, uint32_t bit) { if (!value) state.failures |= bit; }
static void setHandle(Interface* interface, uint32_t value) { std::memcpy(interface->bytes + 0xa8, &value, 4); }
static void reset(uint32_t mode, uint32_t configured) {
    state = LocalState{}; state.mode = mode; state.configured = configured;
    std::memset(state.interface.bytes, 0x5a, sizeof(state.interface.bytes));
    std::memset(state.other.bytes, 0xa5, sizeof(state.other.bytes));
    setHandle(&state.interface, mode == InvalidHandle ? 0 : validHandle);
    setHandle(&state.other, validHandle);
    if (mode == TargetNaN) state.target[0] = NAN;
    if (mode == TargetInfinity) state.target[1] = INFINITY;
    if (mode == TooFar) state.target[0] = state.current[0] + 2;
    if (mode == TargetWorldRange) state.target[2] = 1000001;
    if (mode == ExactBoundary) { std::memcpy(state.target, state.current, 12); state.target[0] += 1; }
    if (mode == DiagonalTooFar) { std::memcpy(state.target, state.current, 12); state.target[0] += .8f; state.target[1] += .8f; }
}
extern "C" {
__attribute__((noinline,optnone,visibility("default"))) bool ncc_position_setter(void* context, uint32_t value, const Variant* variant) {
    event('S'); ++state.setters; allSetters.fetch_add(1, std::memory_order_relaxed);
    check(context == state.setter.context && value == state.setter.state && variant == state.setter.pointer, 2);
    check(!variant || !std::memcmp(variant, &state.setter.bytes, sizeof(Variant)), 4);
    if (state.mode == ChangedByOriginal) setHandle(static_cast<Interface*>(context), changedHandle);
    // The bridge must snapshot a heap Variant before the original body changes it.
    if (state.mode == Heap && variant && !(variant->type & 1))
        std::memset(reinterpret_cast<void*>(variant->payload[0]), 0, 12);
    return state.setter.accepted;
}
__attribute__((noinline,optnone,visibility("default"))) uintptr_t ncc_position_executor(void*, void*, void*, void*, void*);
}
static bool invokeSetter(uint32_t mode, void* context) {
    Variant variant; variant.type = typeToken() | 1;
    std::memcpy(variant.payload, state.target, 12);
    float* heap = nullptr;
    if (mode == Heap) {
        heap = new float[3]; std::memcpy(heap, state.target, 12);
        variant.type = typeToken(); variant.payload[0] = reinterpret_cast<uintptr_t>(heap); variant.payload[1] = 0;
    }
    if (mode == WrongType) variant.type = (typeToken() + 8) | 1;
    if (mode == NullPayload) { variant.type = typeToken(); variant.payload[0] = 0; }
    const uint32_t value = mode == WrongEnum ? 4 : 1;
    void* setterContext = mode == WrongContext ? &state.other : context;
    const Variant* pointer = mode == NullVariant ? nullptr : &variant;
    const auto previous = state.setter;
    state.setter = {setterContext, value, pointer, variant, mode == OriginalTrue};
    const bool result = ncc_position_setter(setterContext, value, pointer);
    state.setter = previous;
    delete[] heap;
    return result;
}
static bool invokeExecutor(uintptr_t fn, void* context, Request request, bool nullOutput = false) {
    GuardedBool output;
    const auto previous = state.executor;
    void* result = nullOutput ? nullptr : &output.value;
    state.executor = {reinterpret_cast<void*>(fn), context, &request, result, reinterpret_cast<void*>(0xface)};
    check(ncc_position_executor(reinterpret_cast<void*>(fn), context, &request, result,
          reinterpret_cast<void*>(0xface)) == originalReturn, 8);
    check(output.before == 0x11223344 && !std::memcmp(output.after, "\1\2\3\4\5\6\7", 7), 16);
    if (!nullOutput) check(output.value <= 1, 32);
    state.executor = previous;
    return !nullOutput && output.value;
}
extern "C" {
__attribute__((noinline,optnone,visibility("default"))) uintptr_t ncc_position_executor(
    void* fn, void* context, void* frame, void* output, void* type) {
    const auto& expected = state.executor;
    check(fn == expected.fn && context == expected.context && frame == expected.frame &&
          output == expected.output && type == expected.type, 64);
    const auto request = *static_cast<const Request*>(frame);
    if (reinterpret_cast<uintptr_t>(fn) == writerFn) allWriters.fetch_add(1, std::memory_order_relaxed);
    bool result = false;
    if (request.mode == NestedSame || request.mode == NestedOther) {
        check(!invokeExecutor(writerFn, request.mode == NestedSame ? context : &state.other,
              {Inline, request.configured}), 128);
        result = invokeSetter(Inline, context);
    } else if (request.mode == Duplicate) {
        check(invokeSetter(Inline, context) == bool(request.configured), 256);
        result = invokeSetter(Inline, context);
    } else if (request.mode == RejectedThenValid) {
        check(!invokeSetter(WrongType, context), 512);
        result = invokeSetter(Inline, context);
    } else if (request.mode != EmptyWriter) result = invokeSetter(request.mode, context);
    if (output) *static_cast<uint8_t*>(output) = result;
    return originalReturn;
}
__attribute__((visibility("default"))) uint32_t ncc_position_valid(uint32_t handle) {
    event('v'); return handle == validHandle;
}
__attribute__((visibility("default"))) void* ncc_position_init(void* builder, uint32_t handle) {
    event('I'); ++state.inits;
    check(handle == validHandle && !(reinterpret_cast<uintptr_t>(builder) & 7), 1024);
    const unsigned char zero[24]{};
    check(!std::memcmp(builder, zero, 24), 2048);
    check(state.setters && state.getters && !state.commits, 4096);
    state.builder = builder;
    std::memset(builder, 0xbc, 24); std::memcpy(static_cast<char*>(builder) + 16, &handle, 4);
    return state.mode == InitFailure ? nullptr : builder;
}
__attribute__((visibility("default"))) void* ncc_position_write(void* builder, const float* xyz, uint32_t selector) {
    event('W'); ++state.writes;
    check(builder == state.builder && selector == 0 && xyz && !std::memcmp(xyz, state.target, 12), 8192);
    return state.mode == WriteFailure ? nullptr : builder;
}
__attribute__((visibility("default"))) void ncc_position_commit(void* builder) {
    event('C'); ++state.commits; allCommits.fetch_add(1, std::memory_order_relaxed);
    check(builder == state.builder && state.inits == 1 && state.writes == 1 && state.commits == 1, 16384);
}
__attribute__((visibility("default"))) void ncc_position_destroy(void* builder) {
    event('D'); ++state.destroys; check(builder == state.builder, 32768);
}
// This deliberately exposes the engine ABI: output is X8, never the normal X2
// C argument or a float3 HFA return. The production adapter must supply X8.
__attribute__((visibility("default"))) void ncc_position_getter_body(uint32_t handle, uint32_t selector, float* output) {
    event('G'); ++state.getters;
    check(handle == validHandle && selector == (state.adapterOnly ? 0x76543210u : 0), 65536);
    check(output != nullptr, 131072);
    if (!output) return;
    if (state.mode == GetterNoOutput) return;
    std::memcpy(output, state.current, 12);
    if (state.mode == InvalidCurrent) output[0] = NAN;
    if (state.mode == ChangedByGetter) setHandle(&state.interface, changedHandle);
    // Inside a Gum onLeave callback, Frida suppresses reentrant hooks. This
    // synthetic getter therefore runs the nested original writer without a
    // second scope/apply; the outer candidate may still commit once. Ordinary
    // nested calls above run outside listeners and must poison the outer scope.
    if (state.mode == GetterReentry)
        check(!invokeExecutor(writerFn, &state.interface, {Inline, 1}), 262144);
}
__attribute__((naked,noinline,visibility("default"))) void ncc_position_raw_getter() {
    __asm__ volatile("mov x2, x8\nb _ncc_position_getter_body");
}
__attribute__((visibility("default"))) void* ncc_position_type() { return fakeType; }
__attribute__((visibility("default"))) void* ncc_position_filter_type() { return fakeFilterType; }
__attribute__((visibility("default"))) uint64_t ncc_position_setter_count() { return allSetters.load(); }
__attribute__((visibility("default"))) uint64_t ncc_position_commit_count() { return allCommits.load(); }
__attribute__((visibility("default"))) uint64_t ncc_position_writer_count() { return allWriters.load(); }
__attribute__((visibility("default"))) uint32_t ncc_position_adapter_test() {
    reset(Inline, 0); state.adapterOnly = true;
    GuardedXYZ value;
    nightcity_flight_position_get_raw(reinterpret_cast<void*>(&ncc_position_raw_getter), validHandle, 0x76543210, value.xyz);
    check(value.before == 0x1122334455667788 && value.after == 0xaabbccdd && value.last == 0x99aabbccddeeff00, 524288);
    check(!std::memcmp(value.xyz, state.current, 12) && state.getters == 1 && !std::strcmp(state.events, "G"), 1048576);
    return state.failures;
}
__attribute__((visibility("default"))) uint32_t ncc_position_run(uint32_t mode, uint32_t configured) {
    reset(mode, configured);
    bool result = mode == Outside ? invokeSetter(Inline, &state.interface)
        : invokeExecutor(mode == WrongMethod ? unrelatedFn : writerFn, &state.interface, {mode, configured}, mode == NullOutput);
    const bool success = configured && (mode == Inline || mode == Heap || mode == ExactBoundary || mode == GetterReentry);
    check(result == (success || mode == OriginalTrue), 2097152);
    const bool applied = configured && (success || mode == Duplicate || mode == NullOutput);
    const char* events = "S";
    if (mode == EmptyWriter) events = "";
    else if (mode == NestedSame || mode == NestedOther || mode == RejectedThenValid) events = "SS";
    else if (!configured) events = mode == Duplicate ? "SS" : "S";
    else if (applied) events = mode == Duplicate ? "vSvGvIWCDS" : mode == GetterReentry ? "vSvGSvIWCD" : "vSvGvIWCD";
    else if (mode == OriginalTrue || mode == ChangedByOriginal || mode == InvalidHandle) events = "vS";
    else if (mode == ChangedByGetter || mode == InvalidCurrent || mode == GetterNoOutput || mode == TooFar || mode == DiagonalTooFar) events = "vSvG";
    else if (mode == InitFailure) events = "vSvGvID";
    else if (mode == WriteFailure) events = "vSvGvIWD";
    check(!std::strcmp(state.events, events), 4194304);
    check(state.commits == uint32_t(applied), 8388608);
    const uint32_t expectedSetters = (mode == EmptyWriter ? 0 :
        (mode == Duplicate || mode == NestedSame || mode == NestedOther || mode == RejectedThenValid ||
         (configured && mode == GetterReentry)) ? 2 : 1);
    check(state.setters == expectedSetters, 16777216);
    // Once the exact method returns, its scope cannot make another native setter
    // eligible. This also checks cleanup after every rejected and nested case.
    const uint32_t commitsBefore = state.commits;
    check(!invokeSetter(Inline, &state.interface) && state.commits == commitsBefore, 33554432);
    if (state.failures) std::printf("mode %u configured %u failures 0x%x events %s expected %s+S result %u\n",
        mode, configured, state.failures, state.events, events, unsigned(result));
    return state.failures;
}
__attribute__((visibility("default"))) uint32_t ncc_position_replay_test() {
    reset(Inline, 1);
    struct GuardedCandidate { uint64_t before = 0x1122334455667788; nightcity::flight_position::Candidate value;
        uint64_t after = 0x99aabbccddeeff00; } candidate;
    Variant variant; variant.type = typeToken() | 1; std::memcpy(variant.payload, state.target, 12);
    check(!nightcity_flight_position_prepare(&state.interface, 1, &variant, &candidate.value), 1);
    const auto token = nightcity_flight_position_begin(&state.interface, 3);
    check(token && nightcity_flight_position_prepare(&state.interface, 1, &variant, &candidate.value), 2);
    auto copy = candidate.value;
    std::atomic<uint32_t> foreignResult{99};
    std::thread foreign([&] { auto foreignCopy = copy; foreignResult.store(nightcity_flight_position_finish(&foreignCopy, 0)); });
    foreign.join(); check(foreignResult.load() == 0, 4);
    check(!nightcity_flight_position_end(&state.interface, 3, token + 1), 8);
    check(!invokeSetter(Inline, &state.interface), 16);
    check(nightcity_flight_position_finish(&candidate.value, 0), 32);
    check(!nightcity_flight_position_finish(&copy, 0), 64);
    check(nightcity_flight_position_end(&state.interface, 3, token), 128);
    check(!nightcity_flight_position_finish(&copy, 0), 256);
    check(candidate.before == 0x1122334455667788 && candidate.after == 0x99aabbccddeeff00, 512);
    check(state.commits == 1 && !std::strcmp(state.events, "vSvGvIWCD"), 1024);
    if (state.failures) std::printf("replay failures 0x%x events %s\n", state.failures, state.events);
    return state.failures;
}
__attribute__((visibility("default"))) uint32_t ncc_position_workers(uint32_t iterations) {
    std::atomic<uint32_t> failures{0}; std::vector<std::thread> threads;
    for (uint32_t thread = 0; thread < 4; ++thread) threads.emplace_back([&, thread] {
        for (uint32_t i = 0; i < iterations; ++i)
            for (uint32_t mode : {uint32_t(Inline), uint32_t(Heap), uint32_t(Duplicate), uint32_t(NestedSame),
                uint32_t(NestedOther), uint32_t(OriginalTrue), uint32_t(ChangedByGetter), uint32_t(GetterReentry)})
                failures.fetch_or(ncc_position_run(mode, 1));
    });
    for (auto& thread : threads) thread.join();
    return failures.load();
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    void* gadget = dlopen(argv[1], RTLD_NOW);
    if (!gadget) { std::puts(dlerror()); return 2; }
    std::puts("host completed"); return 0;
}
'''


TEST = r'''
try {
 const assert=(v,m)=>{if(!v)throw Error(m);};
 const address=name=>Module.getGlobalExportByName(name);
 const native=(name,ret,args)=>new NativeFunction(address(name),ret,args);
 let entries=0,internalEntries=0,leaves=0;
 const gate=createExecutorGate((fn,ctx,frame)=>{entries++;if(fn.equals(ptr(0xc1)))internalEntries++;return 1;},()=>{leaves++;});
 globalThis.keepGate=gate;
 assert(gate.positionBridgeAvailable,'production position scope exports available');
 gate.positionMethod(ptr(0xc1));gate.observers(true);
 Interceptor.attach(address('ncc_position_executor'),gate.callbacks);Interceptor.flush();
 const type=native('ncc_position_type','pointer',[])();
 const filterType=native('ncc_position_filter_type','pointer',[])();
 const hook=createFlightCaptureHook(address('ncc_position_setter'),filterType,16,8,32);
 globalThis.keepHook=hook;
 assert(hook.positionBridgeAvailable,'production direct setter hook supports position');
 const run=native('ncc_position_run','uint',['uint','uint']);
 const adapter=native('ncc_position_adapter_test','uint',[]);
 const replay=native('ncc_position_replay_test','uint',[]);
 const workers=native('ncc_position_workers','uint',['uint']);
 const setters=native('ncc_position_setter_count','uint64',[]);
 const commits=native('ncc_position_commit_count','uint64',[]);
 const writers=native('ncc_position_writer_count','uint64',[]);
 assert(adapter()===0,'raw X8 adapter arguments and exact 12-byte output guards');
 assert(run(0,0)===0,'unconfigured exact writer fails closed');
 assert(entries===0&&internalEntries===0&&leaves===0,'exact writer has no JavaScript callbacks even unconfigured');
 const configure=native('nightcity_flight_position_configure','uint',['pointer','uint','uint','pointer','pointer','pointer','pointer','pointer','pointer']);
 const helpers=['valid','init','write','commit','destroy','raw_getter'].map(name=>address('ncc_position_'+name));
 assert(configure(type,16,4,...helpers)===0,'wrong type size refused');
 assert(configure(type,12,8,...helpers)===0,'wrong type alignment refused');
 assert(configure(type,12,4,ptr(0),...helpers.slice(1))===0,'missing helper refused');
 assert(configure(type,12,4,...helpers)===1,'exact native helpers configured');
 assert(configure(type,12,4,...helpers)===1,'same immutable configuration accepted');
 assert(configure(type.add(8),12,4,...helpers)===0,'different type cannot replace configured type');
 console.log('PASS native position adapter: production raw X8 adapter, exact handle/selector and 12-byte guarded output, invalid and immutable type configuration, unconfigured fail closed');
 for(let mode=0;mode<30;mode++) {
   const entriesBefore=entries,settersBefore=setters().toNumber(),commitsBefore=commits().toNumber();
   const result=run(mode,1);
   assert(result===0,'mode '+mode+' host checks 0x'+result.toString(16));
   assert(entries===entriesBefore+(mode===22?1:0),'mode '+mode+' only unrelated method may enter JavaScript');
   const count=mode===24?1:[17,18,19,20,29].includes(mode)?3:2;
   assert(setters().toNumber()===settersBefore+count,'mode '+mode+' each original setter exactly once');
   assert(commits().toNumber()===commitsBefore+([0,1,17,23,27,29].includes(mode)?1:0),'mode '+mode+' at most one native sequence');
   assert(internalEntries===0&&leaves===0,'owned writer and helpers never enter JavaScript');
 }
 assert(replay()===0,'guarded native candidates reject copied replay, expired token and different native thread');
 console.log('PASS native position integration: exact writer and context, inline and heap snapshots, original arguments and Bool results, original false before apply, once-only init/write/commit/destroy, bounded finite positions, handle revalidation, wrong enum/type/null, unrelated calls unchanged, nested writers poisoned, duplicate/rejected attempts and replay refused');
 gate.busy(true);const before=entries;
 const code=workers(100);
 assert(code===0,'four native threads: 0x'+code.toString(16));
 assert(entries===before&&internalEntries===0&&leaves===0,'concurrent bridge requires no JavaScript callbacks');
 gate.busy(false);
 assert(writers().toNumber()>3200,'original owned writer bodies remain executed');
 console.log('PASS native position concurrency: four native threads, original executor and setter once, same helper ABI and independent scopes, no JavaScript per-frame callbacks; Frida '+Frida.version);
}catch(e){console.log('FAIL '+e.stack);}
'''


def section(source, name):
    return source.split('// BEGIN ' + name, 1)[1].split('// END ' + name, 1)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gadget', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    capture_header = root / 'overlay/flight_capture.h'
    position_header = root / 'overlay/flight_position.h'
    runtime = (root / 'runtime/red4ext_hooks.js').read_text()
    overlay = (root / 'overlay/overlay.mm').read_text()
    gate = section(runtime, 'NATIVE EXECUTOR GATE')
    atomics = section(overlay, 'RUNTIME ATOMIC HELPERS')
    capture_exports = section(overlay, 'FLIGHT CAPTURE EXPORTS')
    position_exports = section(overlay, 'FLIGHT POSITION EXPORTS')
    temporary = tempfile.TemporaryDirectory(prefix='nightcity-flight-position-') if args.output is None else None
    directory = args.output or Path(temporary.name)
    directory.mkdir(parents=True, exist_ok=True)
    gadget = directory / 'FridaGadget.dylib'
    if args.gadget.resolve() != gadget.resolve():
        shutil.copy2(args.gadget, gadget)
    (directory / 'FridaGadget.config').write_text(json.dumps({'interaction': {
        'type': 'script', 'path': str(directory / 'probe.js'), 'on_load': 'resume'}}))
    host = ''.join('#include "' + str(header) + '"\n' for header in [capture_header, position_header])
    (directory / 'host.cpp').write_text(host + atomics + capture_exports + position_exports + HOST)
    (directory / 'probe.js').write_text(gate + TEST)
    subprocess.run(['clang++', '-std=c++17', '-O2', '-arch', 'arm64', '-Wl,-export_dynamic',
                    '-o', str(directory / 'host'), str(directory / 'host.cpp')], check=True)
    completed = subprocess.run([str(directory / 'host'), str(gadget)], capture_output=True,
                               text=True, timeout=60, check=True)
    output = completed.stdout + completed.stderr
    (directory / 'native-flight-position.txt').write_text(output)
    required = ['PASS native position adapter:', 'PASS native position integration:',
                'PASS native position concurrency:', 'host completed']
    if 'FAIL' in output or any(marker not in output for marker in required):
        raise AssertionError(output)
    # A nearby nonmatching writer must fail the successful write case. This
    # proves the positive result depends on the production exact-method scope.
    negative = TEST.replace('gate.positionMethod(ptr(0xc1))', 'gate.positionMethod(ptr(0xc3))', 1)
    negative = negative.replace("assert(entries===0&&internalEntries===0&&leaves===0,'exact writer has no JavaScript callbacks even unconfigured');", '')
    try:
        (directory / 'probe.js').write_text(gate + negative)
        rejected = subprocess.run([str(directory / 'host'), str(gadget)], capture_output=True,
                                  text=True, timeout=60, check=True)
        negative_output = rejected.stdout + rejected.stderr
        (directory / 'native-flight-position-negative-control.txt').write_text(negative_output)
        if 'FAIL Error: mode 0 host checks 0xe00000' not in negative_output:
            raise AssertionError('Missing exact-method negative-control failure:\n' + negative_output)
    finally:
        (directory / 'probe.js').write_text(gate + TEST)
    report = {
        'isolated_host_not_game_acceptance': True,
        'runtime_sha256': hashlib.sha256(runtime.encode()).hexdigest(),
        'position_header_sha256': hashlib.sha256(position_header.read_bytes()).hexdigest(),
        'capture_header_sha256': hashlib.sha256(capture_header.read_bytes()).hexdigest(),
        'position_exports_sha256': hashlib.sha256(position_exports.encode()).hexdigest(),
        'gadget_sha256': hashlib.sha256(gadget.read_bytes()).hexdigest(),
        'threads': 4, 'worker_iterations': 100, 'integration_modes': 30,
        'exact_method_negative_control': 'Nonmatching writer refuses native apply (0xe00000)',
        'getter_reentry_observation': 'Frida suppresses listener reentry; nested original stays false and outer commits once',
        'checks': ['actual production exports, raw X8 adapter and runtime CModule factories',
                   '12-byte getter and 1-byte Bool result guards', 'exact helper arguments and order',
                   'original executor and direct setter called once with original arguments',
                   'original false before native apply; true original preserved without apply',
                   'once-only zeroed 24-byte builder init, position write, commit and destroy',
                   'inline and heap Variant snapshot', 'unconfigured and immutable type configuration',
                   'exact function and context scope; unrelated/outside calls preserved',
                   'nested writers poison outer scope; synthetic getter reentry cannot issue another apply',
                   'duplicate attempt, failed attempt, copied candidate and expired scope reject replay',
                   'target/current finite, world-coordinate bound and Euclidean step <= 1 metre',
                   'handle rejected or changed before/after getter', 'helper failure cleanup',
                   'four-thread scope isolation and zero internal JavaScript callbacks'],
    }
    (directory / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(output, end='')
    print(json.dumps(report, indent=2))
    if temporary:
        temporary.cleanup()


if __name__ == '__main__':
    main()
