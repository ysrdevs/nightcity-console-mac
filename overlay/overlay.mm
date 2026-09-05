// CP2077 macOS overlay - Phase 2 complete: Dear ImGui in-game console with input.
//   * Renders an ImGui console onto the live game frame via a -[<cmdbuf> presentDrawable:] swizzle.
//   * Captures input via a -[NSApplication sendEvent:] swizzle (main thread) into a locked queue,
//     drained on the render thread so ALL ImGui calls stay single-threaded.
//   * Toggle with the backtick/tilde (`) key or F1. When open, input is swallowed from the game.
//   * Submitting a line writes it to /tmp/cp2077_cmd.txt (the existing Frida command channel);
//     the console tails /tmp/cp2077_out.txt for results. Fully decoupled from the Frida executor.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <string>
#include <vector>
#include <deque>
#include <mutex>
#include <atomic>
#include <thread>
#include <unistd.h>
#include <set>
#include <vector>
#include <unordered_map>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <cctype>
#include <dirent.h>
#include <sys/stat.h>
#include <algorithm>
#include <cstdint>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
// PUC-Lua 5.1.5 (interpreter-only, no JIT, W^X-safe). C headers, so wrap for ObjC++.
// This is the runtime that will host CET-style Lua mods (Q6 bring-up).
extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

// ---- logging ----
static void olog(const char* fmt, ...) {
    char buf[600]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    FILE* f = fopen("/tmp/cp2077_overlay.log", "a"); if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    fprintf(stderr, "[OVERLAY] %s\n", buf);
}

// ---- state ----
// presentDrawable: is implemented per-GPU-family command-buffer class (AGXG13X/G14/G15/G16F/...). The class
// the game uses varies by chip, so we swizzle EVERY command-buffer class that has the method and keep each
// one's original IMP keyed by its Method, looked up by the live buffer's class at call time.
static std::unordered_map<void*, IMP> g_origPresents;   // Method* -> original presentDrawable IMP
static SEL g_presentSel = NULL;
static IMP g_origSendEvent = NULL;
static bool g_imguiInit = false;
static unsigned long g_frame = 0;
static std::atomic<bool> g_show{false};
static std::atomic<bool> g_focusInput{false};
static std::atomic<int>  g_activeTab{0};        // 0 Console, 1 Items, 2 Quick
static std::atomic<bool> g_tabReq{false};       // a keyboard tab-switch was requested
static std::atomic<bool> g_itemsTabEntered{false};
static std::atomic<bool> g_pinTopReq{false};    // Cmd+P pins the current top search result
static std::vector<std::string> g_lines;
static char g_input[512] = {0};
static std::vector<std::string> g_history;   // submitted commands (oldest first)
static int g_historyPos = -1;                // -1 = current edit line; else index into g_history
static const char* OUT_PATH = "/tmp/cp2077_out.txt";
static const char* CMD_PATH = "/tmp/cp2077_cmd.txt";
#include <ctime>
// set by the `reload` verb + the once/sec mtime poll; consumed by the tab engine below.
static std::atomic<bool> g_tabsDirty{true};   // true forces a rebuild on next frame

// ---- bisection kill-switch (NCC_MODE env): full = hook + render (default),
// passthru = hook present but never render, off = don't swizzle present at all.
// Lets a tester localize stutter in-game without rebuilding. ----
enum NccMode { NCC_FULL = 0, NCC_PASSTHRU = 1, NCC_OFF = 2 };
static NccMode g_mode = NCC_FULL;
static const char* modeName() { return g_mode == NCC_OFF ? "off" : g_mode == NCC_PASSTHRU ? "passthru" : "full"; }
static void readMode() {
    char buf[32] = {0};
    const char* m = getenv("NCC_MODE");                 // 1) env var (terminal/dev launch)
    if (!m) {                                            // 2) else ~/nightcity_mode.txt (for the .app)
        const char* home = getenv("HOME");
        if (home) {
            char path[1024]; snprintf(path, sizeof(path), "%s/nightcity_mode.txt", home);
            FILE* f = fopen(path, "r");
            if (f) { if (fgets(buf, sizeof(buf), f)) m = buf; fclose(f); }
        }
    }
    if (!m) return;
    if (!strncmp(m, "off", 3)) g_mode = NCC_OFF;
    else if (!strncmp(m, "passthru", 8)) g_mode = NCC_PASSTHRU;
    else g_mode = NCC_FULL;
}

// ---- frame-time instrumentation: measure the game's real per-frame cadence at nextDrawable
// (called once per frame regardless of how it presents, so it works in every mode). Logs avg +
// worst-case present interval every 120 frames so we get milliseconds instead of "feels stuttery". ----
static double g_lastFrameT = 0.0, g_ftSum = 0.0, g_ftMax = 0.0; static int g_ftCount = 0;
static void frameTick() {
    double now = CACurrentMediaTime();
    if (g_lastFrameT > 0.0) {
        double dt = (now - g_lastFrameT) * 1000.0;   // ms
        g_ftSum += dt; if (dt > g_ftMax) g_ftMax = dt; g_ftCount++;
        if (g_ftCount >= 120) {
            olog("frametime: avg=%.2fms max=%.2fms over %d frames (mode=%s console=%s)",
                 g_ftSum / g_ftCount, g_ftMax, g_ftCount, modeName(), g_show.load() ? "open" : "closed");
            g_ftSum = 0.0; g_ftMax = 0.0; g_ftCount = 0;
        }
    }
    g_lastFrameT = now;
}

// ---- input event queue (main thread -> render thread) ----
struct InEvent { int type; int code; bool down; unsigned ch; float x; float y; };
static std::deque<InEvent> g_queue;
static std::mutex g_qmtx;

// ---- virtual mouse cursor (delta-accumulated; render-thread owned) ----
// The game associates the OS cursor off and hides it during gameplay, so absolute window coords are
// frozen. We accumulate raw mouse deltas into our own cursor position (framebuffer px) and let ImGui
// draw a software cursor, so the mouse works regardless of the game's pointer-capture state.
static float g_mx = 0.0f, g_my = 0.0f;
static bool  g_mouseInit = false;
static std::atomic<bool> g_recenterMouse{false};   // center the cursor when the console opens

// ---- command channel ----
static void refreshOut() {
    FILE* f = fopen(OUT_PATH, "r"); if (!f) return;
    g_lines.clear();
    char line[2048];
    while (fgets(line, sizeof(line), f)) { size_t n = strlen(line); if (n && line[n-1] == '\n') line[n-1] = 0; g_lines.push_back(line); }
    fclose(f);
    if (g_lines.size() > 400) g_lines.erase(g_lines.begin(), g_lines.end() - 400);
}
static unsigned g_cmdSeq = 0;
static void submitCommand(const char* c) {
    // Prefix a monotonic sequence so repeated identical commands are never de-duped
    // by the Frida poller (it compares raw file contents). The JS strips the "<seq>\t".
    FILE* f = fopen(CMD_PATH, "w"); if (f) { fprintf(f, "%u\t%s\n", ++g_cmdSeq, c); fclose(f); }
    olog("submitted: %s", c);
}
static void appendOut(const char* s) { FILE* f = fopen(OUT_PATH, "a"); if (f) { fprintf(f, "%s\n", s); fclose(f); } }
// ============================================================================
// Native MINI-CET (Q12 foundation): resolve + call engine functions directly in-process,
// no /tmp round-trip. Keystone for non-blocking Game.* (including inside onDraw). Ported from
// the Frida MINI-CET in red4ext_hooks.js. Staged bring-up: this proves native resolution + a
// no-arg call from the render thread (same thread onDraw uses, so success here means onDraw can
// call the engine too). Arg marshalling + the full Game proxy come next.
// ============================================================================
typedef uint64_t (*NccExecFn)(void* fn, void* ctx, void* frame, void* result, void* retType);
typedef void*    (*NccRegGetter)();
typedef void*    (*NccGetClassFn)(void* reg, uint64_t nameHash);

static uint64_t nccFnv1a64(const char* s){ uint64_t h=0xCBF29CE484222325ULL; for(;*s;++s){ h^=(uint64_t)(uint8_t)*s; h*=0x100000001b3ULL; } return h; }

// Main game executable load address (the MH_EXECUTE image). Offsets like 0x2173120 add to this.
// Selecting by Mach-O filetype (not a fixed dyld index) is the robust form of the old index bug.
static uintptr_t nccGameBase(){
    static uintptr_t base = 0;
    if (base) return base;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++){
        const struct mach_header* h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE){ base = (uintptr_t)h; break; }
    }
    return base;
}

static void* g_nccReg = nullptr; static NccGetClassFn g_nccGetClass = nullptr;
static void nccEnsureReg(){
    if (g_nccReg) return;
    uintptr_t base = nccGameBase(); if (!base) return;
    NccRegGetter getter = (NccRegGetter)(base + 0x2188e8c);   // CRTTISystem::Get
    g_nccReg = getter(); if (!g_nccReg) return;
    void* vt = *(void**)g_nccReg;                              // registry vtable
    g_nccGetClass = *(NccGetClassFn*)((uintptr_t)vt + 0x10);   // GetClass @ vt+0x10
}
static void* nccClsByName(const char* n){ nccEnsureReg(); if(!g_nccGetClass) return nullptr; return g_nccGetClass(g_nccReg, nccFnv1a64(n)); }

struct NccFn { void* fn; void* retType; bool isStatic; };
// Walk the class chain; check instance funcs (CClass+0x48) then static funcs (+0x58); match fn+0x10 == fnv(method).
static bool nccResolveFunc(const char* className, const char* method, NccFn* out){
    void* cls = nccClsByName(className); if(!cls) return false;
    uint64_t mh = nccFnv1a64(method);
    while (cls){
        const uintptr_t offs[2] = {0x48, 0x58};
        for (int oi=0; oi<2; oi++){
            void* fp = *(void**)((uintptr_t)cls + offs[oi]);
            uint32_t cnt = *(uint32_t*)((uintptr_t)cls + offs[oi] + 8);
            if (fp) for (uint32_t i=0; i<cnt; i++){
                void* f = *(void**)((uintptr_t)fp + i*8); if(!f) continue;
                if (*(uint64_t*)((uintptr_t)f + 0x10) == mh){
                    void* rp = *(void**)((uintptr_t)f + 0x18);
                    out->fn = f; out->retType = rp ? *(void**)rp : nullptr; out->isStatic = (oi==1);
                    return true;
                }
            }
        }
        cls = *(void**)((uintptr_t)cls + 0x10);                // parent class
    }
    return false;
}
static void nccHexDump(const char* label, const void* p, int n){
    if(!p){ appendOut((std::string(label)+" = (null)").c_str()); return; }
    std::string s = label; s += " = ";
    const uint8_t* b = (const uint8_t*)p; char h[4];
    for(int i=0;i<n;i++){ snprintf(h,sizeof(h),"%02x ", b[i]); s += h; }
    appendOut(s.c_str());
}
// No-arg invoke: minimal frame (just ParamEnd) + executor call. result16 = 16-byte out buffer.
// Heap-allocated (16-byte aligned, like Frida Memory.alloc) to match the working hooks.js path.
// Returns the executor's own return code (for diagnostics).
static uint64_t nccCallNoArg(void* fn, void* ctx, void* retType, uint8_t* result16){
    NccExecFn Exec = (NccExecFn)(nccGameBase() + 0x2173120);
    uint8_t* bc = (uint8_t*)calloc(1, 64); if(bc) bc[0]=0x26;  // ParamEnd
    uint8_t* locals = (uint8_t*)calloc(1, 0x40);
    uint8_t* frame  = (uint8_t*)calloc(1, 0x90);
    if(frame){ *(void**)(frame+0x00)=bc; *(void**)(frame+0x10)=locals; *(void**)(frame+0x18)=locals; *(void**)(frame+0x40)=ctx; }
    memset(result16,0,16);
    uint64_t rc = Exec(fn, ctx, frame, result16, retType);
    nccHexDump("  locals[0:0x20] post", locals, 0x20);
    nccHexDump("  frame[0:0x20] post", frame, 0x20);
    free(bc); free(locals); free(frame);
    return rc;
}
// Fetch a LIVE player handle via the Q7 bridge right before a native call (avoids the stale-handle gap).
static uint64_t nccBridgeGetPlayer(){
    static unsigned bseq = 1000000;
    unsigned seq = ++bseq;
    { FILE* f=fopen("/tmp/cp2077_lreq.txt","w"); if(!f) return 0; fprintf(f,"%u\tGetPlayer\t0\n",seq); fclose(f); }
    for(int t=0;t<80;t++){ usleep(5000);   // ~400ms cap: this runs on the render thread, only once (GI is cached after)
        FILE* r=fopen("/tmp/cp2077_lres.txt","r"); if(!r) continue;
        char line[4096]; uint64_t val=0; bool got=false;
        while(fgets(line,sizeof(line),r)){ char* t1=strchr(line,'\t'); if(!t1)continue; char* t2=strchr(t1+1,'\t'); if(!t2)continue; *t1=0; *t2=0;
            if((unsigned)strtoul(line,nullptr,10)!=seq) continue;
            if(strncmp(t1+1,"ptr",3)==0||strncmp(t1+1,"int",3)==0) val=strtoull(t2+1,nullptr,0); got=true; break; }
        fclose(r); if(got) return val;
    }
    return 0;
}
// ---- arg marshalling (Q12 step 1): ported 1:1 from callFunc() in red4ext_hooks.js ----
// Param-type name hashes (the GetName hash of each param's type meta); from the T_* consts in hooks.js.
static const uint64_t NCC_T_I32  = 0xb9a127f5b4a621bfULL, NCC_T_U32 = 0x3d2e9dd9e3c28d8cULL;
static const uint64_t NCC_T_I64  = 0xb9902ff5b497bc24ULL, NCC_T_U64 = 0x3d3f99d9e3d0f9f3ULL;
static const uint64_t NCC_T_F32  = 0xb64f4a0accc8a8c5ULL, NCC_T_BOOL= 0xf7bdd5a7c820889dULL;
static const uint64_t NCC_T_CNAME= 0xa5e23de2a2657af9ULL, NCC_T_TDB = 0x4072151ff3dcf7bcULL;
static const uint64_t NCC_T_ITEM = 0xd15b2274885d7f7dULL;
// refcnt sentinel a handle's second word points at (matches Memory.alloc(8)+writeU32(0x100000)x2 in hooks.js).
static uint32_t g_nccRefcnt[2] = { 0x100000, 0x100000 };

static uint32_t nccCrc32(const char* s){ uint32_t crc=0xFFFFFFFFu; for(;*s;++s){ uint32_t c=(crc^(uint8_t)*s)&0xFFu; for(int k=0;k<8;k++) c=(c&1)?(0xEDB88320u^(c>>1)):(c>>1); crc=(crc>>8)^c; } return crc^0xFFFFFFFFu; }
// type meta -> its name hash (instance vtable +0x10 = GetName), mirrors nameOf() in hooks.js.
typedef uint64_t (*NccGetNameFn)(void* obj);
static uint64_t nccTypeName(void* type){ if(!type) return 0; void* vt=*(void**)type; if(!vt) return 0; NccGetNameFn fn=*(NccGetNameFn*)((uintptr_t)vt+0x10); return fn?fn(type):0; }

// Marshal string args by the function's declared param types and invoke the executor in-process.
// Arg forms: "@player"/"@self" -> the ctx handle; "@0x..." -> an explicit handle ptr; otherwise a scalar
// parsed by the param type. result16 = 16-byte out buffer. Returns the executor rc; on a marshalling
// error returns 0 and fills *err. gameItemID (T_ITEM) is not yet ported (still goes via the bridge).
static uint64_t nccCall(const NccFn* f, void* ctx, int argc, const char** argv, uint8_t* result16, std::string* err){
    NccExecFn Exec = (NccExecFn)(nccGameBase() + 0x2173120);
    void* pEntries = *(void**)((uintptr_t)f->fn + 0x28);
    uint32_t pCount = *(uint32_t*)((uintptr_t)f->fn + 0x30);
    uint8_t* locals = (uint8_t*)calloc(1, 0x40 + (size_t)argc*0x20);
    std::vector<void*> props;
    auto fail = [&](const std::string& m)->uint64_t{ if(err)*err=m; for(void* cp:props) free(cp); free(locals); return 0; };
    for(int i=0;i<argc;i++){
        if((uint32_t)i >= pCount) return fail("too many args (fn takes "+std::to_string(pCount)+")");
        void* prop  = *(void**)((uintptr_t)pEntries + i*8);
        void* ptype = *(void**)prop;                 // prop.readPointer()
        uint64_t tn = nccTypeName(ptype);
        size_t off  = 0x20 + (size_t)i*0x20;
        uint8_t* dst = locals + off;
        const char* a = argv[i];
        if (a[0]=='@'){
            void* inst = (strcmp(a,"@player")==0||strcmp(a,"@self")==0) ? ctx : (void*)strtoull(a+1,nullptr,0);
            if(!inst) return fail(std::string("no instance for ")+a);
            *(void**)dst = inst; *(void**)(dst+8) = g_nccRefcnt;          // handle = {inst, refcnt}
        }
        else if (tn==NCC_T_I32 || tn==NCC_T_U32){ *(uint32_t*)dst = (uint32_t)strtoul(a,nullptr,0); }
        else if (tn==NCC_T_I64 || tn==NCC_T_U64){ *(uint64_t*)dst = (uint64_t)strtoull(a,nullptr,0); }
        else if (tn==NCC_T_F32){ *(float*)dst = strtof(a,nullptr); }
        else if (tn==NCC_T_BOOL){ *(uint8_t*)dst = (strcmp(a,"true")==0||strcmp(a,"1")==0)?1:0; }
        else if (tn==NCC_T_CNAME){ *(uint64_t*)dst = nccFnv1a64(a); }
        else if (tn==NCC_T_TDB){ uint32_t h=nccCrc32(a); dst[0]=h&0xff; dst[1]=(h>>8)&0xff; dst[2]=(h>>16)&0xff; dst[3]=(h>>24)&0xff; dst[4]=(uint8_t)strlen(a); dst[5]=dst[6]=dst[7]=0; }
        else if (tn==NCC_T_ITEM){ return fail("gameItemID arg not yet native (use the bridge for GiveItem)"); }
        else { // enum or other: accept a plain integer literal, else unsupported
            char* endp=nullptr; unsigned long long v=strtoull(a,&endp,0);
            if(endp && *endp==0){ *(uint64_t*)dst = v; }
            else { char hb[24]; snprintf(hb,sizeof(hb),"0x%llx",(unsigned long long)tn); return fail(std::string("unsupported arg type ")+hb+" for \""+a+"\""); }
        }
        uint8_t* cp = (uint8_t*)calloc(1,0x30); *(void**)cp = ptype; *(uint32_t*)(cp+0x20) = (uint32_t)off;
        props.push_back(cp);
    }
    uint8_t* bc = (uint8_t*)calloc(1, 16 + (size_t)argc*9);
    size_t o=0; for(int i=0;i<argc;i++){ bc[o++]=0x18; *(void**)(bc+o)=props[i]; o+=8; } bc[o]=0x26; // ParamEnd
    uint8_t* frame = (uint8_t*)calloc(1, 0x90);
    *(void**)(frame+0x00)=bc; *(void**)(frame+0x10)=locals; *(void**)(frame+0x18)=locals; *(void**)(frame+0x40)=ctx;
    memset(result16,0,16);
    uint64_t rc = Exec(f->fn, ctx, frame, result16, f->retType);
    for(void* cp:props) free(cp); free(bc); free(locals); free(frame);
    return rc;
}

// ---- raw-item marshaller (Q12 step 2): ported from callFuncRaw() in red4ext_hooks.js ----
// For in-code call chains where args are pre-encoded values (handles, raw buffers, scalars) rather
// than strings. Needed for the native handle chain (GameInstance is passed as a raw buffer).
enum { NCC_HANDLE, NCC_RAW, NCC_I32, NCC_U64 };
struct NccItem { int kind; void* inst; const void* raw; int n; uint64_t v; };
static uint64_t nccCallRaw(const NccFn* f, void* ctx, const std::vector<NccItem>& items, uint8_t* result16){
    NccExecFn Exec = (NccExecFn)(nccGameBase() + 0x2173120);
    void* pEntries = *(void**)((uintptr_t)f->fn + 0x28);
    uint8_t* locals = (uint8_t*)calloc(1, 0x40 + items.size()*0x20);
    std::vector<void*> props;
    for(size_t i=0;i<items.size();i++){
        void* prop  = *(void**)((uintptr_t)pEntries + i*8);
        void* ptype = *(void**)prop;
        size_t off  = 0x20 + i*0x20; uint8_t* dst = locals + off;
        const NccItem& it = items[i];
        if(it.kind==NCC_HANDLE){ *(void**)dst = it.inst; *(void**)(dst+8) = g_nccRefcnt; }
        else if(it.kind==NCC_RAW){ memcpy(dst, it.raw, it.n); }
        else if(it.kind==NCC_I32){ *(uint32_t*)dst = (uint32_t)it.v; }
        else if(it.kind==NCC_U64){ *(uint64_t*)dst = it.v; }
        uint8_t* cp = (uint8_t*)calloc(1,0x30); *(void**)cp = ptype; *(uint32_t*)(cp+0x20) = (uint32_t)off; props.push_back(cp);
    }
    uint8_t* bc = (uint8_t*)calloc(1, 16 + items.size()*9);
    size_t o=0; for(size_t i=0;i<items.size();i++){ bc[o++]=0x18; *(void**)(bc+o)=props[i]; o+=8; } bc[o]=0x26;
    uint8_t* frame = (uint8_t*)calloc(1, 0x90);
    *(void**)(frame+0x00)=bc; *(void**)(frame+0x10)=locals; *(void**)(frame+0x18)=locals; *(void**)(frame+0x40)=ctx;
    memset(result16,0,16);
    uint64_t rc = Exec(f->fn, ctx, frame, result16, f->retType);
    for(void* cp:props) free(cp); free(bc); free(locals); free(frame);
    return rc;
}
static bool nccSane(void* p){ uintptr_t v=(uintptr_t)p; return v>0x10000ULL && v<0x800000000000ULL; }
// A usable engine object: sane pointer whose vtable is also a sane pointer. Rejects null and the common
// stale/freed case (zeroed vtable). MUST gate every instance call so a bad ctx never reaches the executor
// (a null/garbage ctx makes the executor dereference it and hard-crash, which Lua pcall cannot catch).
static bool nccValidObject(void* p){ return nccSane(p) && nccSane(*(void**)p); }
static bool nccResolveAny(const char* const* classes, int nc, const char* method, NccFn* out){
    for(int i=0;i<nc;i++) if(nccResolveFunc(classes[i], method, out)) return true;
    return false;
}
// Live-player resolution (mirrors getGI -> getViaGetter('GetPlayerSystem') -> GetLocalPlayer* in hooks.js).
// Bootstraps from the bridge player each call, walks to the GameInstance, then resolves the authoritative
// local player NATIVELY so the returned handle is always live (never a stale snapshot). `vb` logs each stage.
// CRITICAL: GetPlayerSystem must be called with the PLAYER (boot) as ctx - the proven path. Passing the
// GameInstance pointer as ctx makes the executor virtual-dispatch on the wrong object and crashes the game.
static void* g_nccLastPlayer = nullptr;
static void* nccGetLivePlayer(bool vb){
    char b[160];
    void* boot = (void*)nccBridgeGetPlayer();
    if(!nccValidObject(boot)){ if(vb) appendOut("  [chain] bridge bootstrap player invalid (not in game?)"); g_nccLastPlayer=nullptr; return nullptr; }
    // 1. PlayerPuppet.GetGame(player) -> GameInstance wrapper (16B in the result buffer)
    NccFn gg; if(!nccResolveFunc("PlayerPuppet","GetGame",&gg)){ if(vb) appendOut("  [chain] PlayerPuppet.GetGame NOT FOUND"); return nullptr; }
    uint8_t gi[16]; nccCallRaw(&gg, boot, {}, gi);
    if(vb){ snprintf(b,sizeof(b),"  [chain] GetGame -> gi[0:8]=0x%llx gi[8:16]=0x%llx",(unsigned long long)*(uint64_t*)gi,(unsigned long long)*(uint64_t*)(gi+8)); appendOut(b); }
    // 2. GameInstance.GetPlayerSystem(gi) -> player system; try gi as 8 then 16 bytes. ctx = the player (boot).
    const char* giClasses[] = {"ScriptGameInstance","GameInstance","gameScriptGameInstance"};
    NccFn gps; if(!nccResolveAny(giClasses,3,"GetPlayerSystem",&gps)){ if(vb) appendOut("  [chain] GetPlayerSystem NOT FOUND"); return nullptr; }
    void* ps=nullptr; uint8_t r[16];
    for(int nb : {8,16}){ std::vector<NccItem> it = {{ NCC_RAW, nullptr, gi, nb, 0 }}; nccCallRaw(&gps, boot, it, r); void* p=*(void**)r;
        if(vb){ snprintf(b,sizeof(b),"  [chain] GetPlayerSystem(gi%d) -> %p",nb,p); appendOut(b); }
        if(nccSane(p)){ ps=p; break; } }
    if(!ps){ if(vb) appendOut("  [chain] no player system"); return nullptr; }
    // 3. <playerSystem>.GetLocalPlayer*() -> live local player game object
    const char* psClasses[] = {"gamePlayerSystem","cpPlayerSystem","PlayerSystem"};
    const char* getters[]   = {"GetLocalPlayerControlledGameObject","GetLocalPlayerMainGameObject","GetLocalPlayer","GetPlayerControlledGameObject"};
    for(const char* c : psClasses) for(const char* g : getters){
        NccFn m; if(!nccResolveFunc(c,g,&m)) continue;
        uint8_t rr[16]; nccCallRaw(&m, ps, {}, rr); void* lp=*(void**)rr;
        if(vb){ snprintf(b,sizeof(b),"  [chain] %s.%s -> %p",c,g,lp); appendOut(b); }
        if(nccSane(lp)){ g_nccLastPlayer=lp; return lp; }
    }
    if(vb) appendOut("  [chain] no local-player getter yielded a sane handle (not in game?)");
    g_nccLastPlayer=nullptr;
    return nullptr;
}
// Player accessor for console/mod calls. Re-resolves natively each call (one bridge bootstrap per call).
static void* nccCachedPlayer(){ return nccGetLivePlayer(false); }
// RENDER-PATH player accessor (safe to call every frame from onDraw). Reuses the cached handle while it is
// still a valid object (cheap, NO bridge); only runs the full chain when the handle goes invalid (first call
// + after a reload/respawn), and backs off when not in game so a menu never hammers the blocking bridge.
static void* nccRenderPlayer(){
    static int cooldown = 0;
    if(nccValidObject(g_nccLastPlayer)) return g_nccLastPlayer;   // valid cached handle -> reuse, no /tmp
    if(cooldown > 0){ cooldown--; return nullptr; }
    void* p = nccGetLivePlayer(false);                            // resolve (one bridge bootstrap)
    if(!p) cooldown = 120;                                        // not in game: ~2s before retrying the bridge
    return p;
}
// Push an executor 16-byte result onto the Lua stack typed by the function's return type. Returns the
// number of Lua values pushed (0 for void). Vector3/Vector4 expand to 3/4 numbers (CET-style).
static int nccPushResult(lua_State* L, void* retType, const uint8_t* res){
    if(!retType) return 0;                                   // void
    uint64_t tn = nccTypeName(retType);
    if(tn==NCC_T_BOOL){ lua_pushboolean(L, res[0]!=0); return 1; }
    if(tn==NCC_T_F32){  lua_pushnumber(L, *(const float*)res); return 1; }
    if(tn==NCC_T_I32){  lua_pushnumber(L, *(const int32_t*)res); return 1; }
    if(tn==NCC_T_U32){  lua_pushnumber(L, *(const uint32_t*)res); return 1; }
    if(tn==nccFnv1a64("Vector4")){ const float* v=(const float*)res; lua_pushnumber(L,v[0]); lua_pushnumber(L,v[1]); lua_pushnumber(L,v[2]); lua_pushnumber(L,v[3]); return 4; }
    if(tn==nccFnv1a64("Vector3")){ const float* v=(const float*)res; lua_pushnumber(L,v[0]); lua_pushnumber(L,v[1]); lua_pushnumber(L,v[2]); return 3; }
    lua_pushnumber(L, (lua_Number)*(const uint64_t*)res); return 1;   // ptr / int64 / cname / handle
}
// Console: liveplayer -> run the native handle chain verbosely and sanity-call GetEntityID on the result.
// Also compares against the bridge player through the SAME nccCallRaw path to isolate object-vs-callpath.
static void luaLivePlayerCmd(){
    char b[200];
    NccFn ge; bool haveGe = nccResolveFunc("gameObject","GetEntityID",&ge);
    appendOut("liveplayer: resolving local player natively...");
    void* lp = nccGetLivePlayer(true);
    static const char* posClasses[] = {"gameObject","gameEntity"};
    NccFn gw; bool haveGw = nccResolveAny(posClasses,2,"GetWorldPosition",&gw);
    if(lp){
        snprintf(b,sizeof(b),"liveplayer NATIVE handle = %p  vtable=0x%llx",lp,(unsigned long long)*(uint64_t*)lp); appendOut(b);
        if(haveGe){ uint8_t r[16]; nccCallRaw(&ge, lp, {}, r);
            snprintf(b,sizeof(b),"  GetEntityID(native handle) = 0x%llx",(unsigned long long)*(uint64_t*)r); appendOut(b); }
        if(haveGw){ uint8_t r[16]; nccCallRaw(&gw, lp, {}, r); float* v=(float*)r;
            snprintf(b,sizeof(b),"  GetWorldPosition(native) = (%.2f, %.2f, %.2f, %.2f)  <- real coords = real player",v[0],v[1],v[2],v[3]); appendOut(b); }
    } else appendOut("liveplayer: native chain FAILED");
    // ---- control: the known-good bridge player, called through the identical path ----
    void* bp = (void*)nccBridgeGetPlayer();
    if(nccSane(bp)){
        snprintf(b,sizeof(b),"  [control] bridge player = %p  vtable=0x%llx",bp,(unsigned long long)*(uint64_t*)bp); appendOut(b);
        if(haveGe){ uint8_t r[16]; nccCallRaw(&ge, bp, {}, r);
            snprintf(b,sizeof(b),"  [control] GetEntityID(bridge player via nccCallRaw) = 0x%llx",(unsigned long long)*(uint64_t*)r); appendOut(b); }
    } else appendOut("  [control] bridge player not sane");
}

// Console: luacall <Class> <Method> <player|ctxHex|0> [args...] -> resolve + marshal string args + call.
// ctx "player" fetches a fresh live handle via the bridge; "0"/"-" passes null (for static fns).
static void luaCallCmd(const char* argline){
    std::vector<std::string> tk; { char* dup=strdup(argline); for(char* t=strtok(dup," \t"); t; t=strtok(nullptr," \t")) tk.push_back(t); free(dup); }
    if(tk.size()<3){ appendOut("usage: luacall <Class> <Method> <player|ctxHex|0> [args...]"); return; }
    NccFn rf;
    if(!nccResolveFunc(tk[0].c_str(), tk[1].c_str(), &rf)){ appendOut((tk[0]+"."+tk[1]+" NOT FOUND").c_str()); return; }
    void* ctx = (tk[2]=="player") ? (void*)nccBridgeGetPlayer()
              : (tk[2]=="live")   ? nccGetLivePlayer(false)   // never-stale native handle
              : (tk[2]=="0"||tk[2]=="-") ? nullptr
              : (void*)strtoull(tk[2].c_str(),nullptr,0);
    std::vector<const char*> argv; for(size_t i=3;i<tk.size();i++) argv.push_back(tk[i].c_str());
    char buf[256];
    snprintf(buf,sizeof(buf),"luacall resolved %s.%s -> fn=%p retType=%p static=%d ctx=%p, %d args",
             tk[0].c_str(),tk[1].c_str(),rf.fn,rf.retType,(int)rf.isStatic,ctx,(int)argv.size());
    appendOut(buf);
    uint8_t res[16]; std::string err;
    uint64_t rc = nccCall(&rf, ctx, (int)argv.size(), argv.empty()?nullptr:argv.data(), res, &err);
    if(!err.empty()){ appendOut((std::string("luacall error: ")+err).c_str()); return; }
    snprintf(buf,sizeof(buf),"luacall %s.%s -> rc=0x%llx result[0:8]=0x%llx result[8:16]=0x%llx",
             tk[0].c_str(),tk[1].c_str(),(unsigned long long)rc,
             (unsigned long long)(*(uint64_t*)res),(unsigned long long)(*(uint64_t*)(res+8)));
    appendOut(buf);
}

// Console: luanative <Class> <Method> [ctxHex|player] -> resolve natively, and call no-arg if a ctx is given.
// Use the literal "player" for ctx to fetch a fresh live handle just before the call.
static void luaNativeTest(const char* args){
    char cls[160]={0}, meth[160]={0}, ctxs[64]={0};
    int got = sscanf(args, "%159s %159s %63s", cls, meth, ctxs);
    if (got < 2){ appendOut("usage: luanative <Class> <Method> [ctxHex]"); return; }
    NccFn rf;
    if (!nccResolveFunc(cls, meth, &rf)){ appendOut((std::string("luanative: ")+cls+"."+meth+" NOT FOUND").c_str()); return; }
    char buf[256];
    snprintf(buf, sizeof(buf), "luanative resolved %s.%s -> fn=%p retType=%p static=%d", cls, meth, rf.fn, rf.retType, (int)rf.isStatic);
    appendOut(buf);
    if (got >= 3){
        void* ctx = (strcmp(ctxs, "player") == 0) ? (void*)nccBridgeGetPlayer() : (void*)strtoull(ctxs, nullptr, 0);
        nccHexDump("  ctx[0:16]", ctx, 16);
        nccHexDump("  retType[0:16]", rf.retType, 16);
        uint8_t res[16]; uint64_t rc = nccCallNoArg(rf.fn, ctx, rf.retType, res);
        snprintf(buf, sizeof(buf), "luanative called %s.%s(ctx=%p) -> exec_rc=0x%llx result[0:8]=0x%llx result[8:16]=0x%llx",
                 cls, meth, ctx, (unsigned long long)rc, (unsigned long long)(*(uint64_t*)res), (unsigned long long)(*(uint64_t*)(res+8)));
        appendOut(buf);
    }
}

static void luaRunExpr(const char* expr);   // Q7: defined with the Lua runtime below
static std::string overlayDir();            // defined below; used by loadLuaMods (Q8)

// Handle a submitted line. `clear`/`help` are local to the overlay; everything else goes to Frida.
static void handleSubmit(const char* cmd) {
    if (strcmp(cmd, "clear") == 0) { FILE* f = fopen(OUT_PATH, "w"); if (f) fclose(f); g_lines.clear(); return; }
    if (strcmp(cmd, "reload") == 0) { g_tabsDirty = true; appendOut("> reload"); appendOut("reloading tabs/ ..."); refreshOut(); return; }
    appendOut((std::string("> ") + cmd).c_str());
    if (strncmp(cmd, "lua ", 4) == 0) { luaRunExpr(cmd + 4); refreshOut(); return; }   // Q7: run Lua in-process
    if (strncmp(cmd, "luanative ", 10) == 0) { luaNativeTest(cmd + 10); refreshOut(); return; }   // Q12: native executor de-risk
    if (strncmp(cmd, "luacall ", 8) == 0) { luaCallCmd(cmd + 8); refreshOut(); return; }            // Q12 step 1: native call WITH args
    if (strcmp(cmd, "liveplayer") == 0) { luaLivePlayerCmd(); refreshOut(); return; }                 // Q12 step 2: native live-player chain
    if (strcmp(cmd, "help") == 0) {
        appendOut("items:  give <Items.X> <qty> | removeitem <Items.X> <qty> | money <n>");
        appendOut("        CET style: Game.AddToInventory(\"Items.X\", n)");
        appendOut("char:   perks <n> | attrs <n> | resetperks | resetattrs | relic <n> | level <n> | streetcred <n>");
        appendOut("        heal | godmode [off] | invis [off] | infammo [off]");
        appendOut("world:  time <h> [m] | slowmo [factor|off] | nopolice [off]");
        appendOut("        teleport save <name> | teleport <name> | teleport <x> <y> <z> | setfact <name> <n>");
        appendOut("misc:   call <Class> <method> [args] | sig <Class> <method> | convdump | clear | help");
        appendOut("tip: Up/Down = command history. Bookmark spots: 'teleport save home' then 'teleport home'");
    } else {
        submitCommand(cmd);
    }
    refreshOut();
}

// ---- macOS virtual keycode -> ImGuiKey (control/nav keys + letters for Ctrl shortcuts) ----
static ImGuiKey macKeyToImGui(unsigned short k) {
    switch (k) {
        case 36: return ImGuiKey_Enter;      case 76: return ImGuiKey_KeypadEnter;
        case 48: return ImGuiKey_Tab;        case 49: return ImGuiKey_Space;
        case 51: return ImGuiKey_Backspace;  case 117: return ImGuiKey_Delete;
        case 53: return ImGuiKey_Escape;
        case 123: return ImGuiKey_LeftArrow; case 124: return ImGuiKey_RightArrow;
        case 125: return ImGuiKey_DownArrow; case 126: return ImGuiKey_UpArrow;
        case 115: return ImGuiKey_Home;      case 119: return ImGuiKey_End;
        case 116: return ImGuiKey_PageUp;    case 121: return ImGuiKey_PageDown;
        case 0: return ImGuiKey_A;  case 11: return ImGuiKey_B; case 8: return ImGuiKey_C;  case 2: return ImGuiKey_D;
        case 14: return ImGuiKey_E; case 3: return ImGuiKey_F;  case 5: return ImGuiKey_G;  case 4: return ImGuiKey_H;
        case 34: return ImGuiKey_I; case 38: return ImGuiKey_J; case 40: return ImGuiKey_K; case 37: return ImGuiKey_L;
        case 46: return ImGuiKey_M; case 45: return ImGuiKey_N; case 31: return ImGuiKey_O; case 35: return ImGuiKey_P;
        case 12: return ImGuiKey_Q; case 15: return ImGuiKey_R; case 1: return ImGuiKey_S;  case 17: return ImGuiKey_T;
        case 32: return ImGuiKey_U; case 9: return ImGuiKey_V;  case 13: return ImGuiKey_W; case 7: return ImGuiKey_X;
        case 16: return ImGuiKey_Y; case 6: return ImGuiKey_Z;
        default: return ImGuiKey_None;
    }
}

// Called on the MAIN thread from the sendEvent swizzle. Only queues data; no ImGui calls.
static void pushEventFromNS(NSEvent* ev) {
    NSEventType t = ev.type;
    std::lock_guard<std::mutex> lk(g_qmtx);
    NSEventModifierFlags mf = ev.modifierFlags;
    int mods = 0;
    if (mf & NSEventModifierFlagControl) mods |= 1;
    if (mf & NSEventModifierFlagShift)   mods |= 2;
    if (mf & NSEventModifierFlagOption)  mods |= 4;
    if (mf & NSEventModifierFlagCommand) mods |= 8;
    g_queue.push_back({5, mods, false, 0, 0, 0});
    if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp) {
        bool down = (t == NSEventTypeKeyDown);
        ImGuiKey k = macKeyToImGui(ev.keyCode);
        if (k != ImGuiKey_None) g_queue.push_back({0, (int)k, down, 0, 0, 0});
        if (down && !(mf & NSEventModifierFlagCommand)) { NSString* s = ev.characters; if (s) { for (NSUInteger i = 0; i < s.length; i++) { unichar c = [s characterAtIndex:i]; if (c >= 32 && c != 127) g_queue.push_back({1, 0, false, (unsigned)c, 0, 0}); } } }
    } else if (t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown ||
               t == NSEventTypeRightMouseUp || t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged ||
               t == NSEventTypeRightMouseDragged) {
        // Movement: queue raw deltas (type 6). deltaX/deltaY keep reporting even when the game has the
        // cursor associated-off, unlike absolute locationInWindow. Scaled to framebuffer px by the
        // window's backing scale; the render thread integrates + clamps these into an absolute pos.
        CGFloat sc = ev.window ? ev.window.backingScaleFactor : 1.0;
        if (ev.deltaX != 0.0 || ev.deltaY != 0.0)
            g_queue.push_back({6, 0, false, 0, (float)(ev.deltaX * sc), (float)(ev.deltaY * sc)});
        if (t == NSEventTypeLeftMouseDown)       g_queue.push_back({3, 0, true,  0, 0, 0});
        else if (t == NSEventTypeLeftMouseUp)    g_queue.push_back({3, 0, false, 0, 0, 0});
        else if (t == NSEventTypeRightMouseDown) g_queue.push_back({3, 1, true,  0, 0, 0});
        else if (t == NSEventTypeRightMouseUp)   g_queue.push_back({3, 1, false, 0, 0, 0});
    } else if (t == NSEventTypeScrollWheel) {
        g_queue.push_back({4, 0, false, 0, (float)ev.scrollingDeltaX * 0.1f, (float)ev.scrollingDeltaY * 0.1f});
    }
}

static void drainEvents() {
    std::lock_guard<std::mutex> lk(g_qmtx);
    ImGuiIO& io = ImGui::GetIO();
    // Center the virtual cursor on first use and each time the console opens, so it's findable.
    // DisplaySize is valid here (renderOverlay sets it just before calling drainEvents).
    if (!g_mouseInit || g_recenterMouse.exchange(false)) {
        g_mx = io.DisplaySize.x * 0.5f; g_my = io.DisplaySize.y * 0.5f; g_mouseInit = true;
        io.AddMousePosEvent(g_mx, g_my);
    }
    for (auto& e : g_queue) {
        switch (e.type) {
            case 0: io.AddKeyEvent((ImGuiKey)e.code, e.down); break;
            case 1: io.AddInputCharacter(e.ch); break;
            case 2: io.AddMousePosEvent(e.x, e.y); break;
            case 3: io.AddMouseButtonEvent(e.code, e.down); break;
            case 4: io.AddMouseWheelEvent(e.x, e.y); break;
            case 5: io.AddKeyEvent(ImGuiMod_Ctrl, e.code & 1); io.AddKeyEvent(ImGuiMod_Shift, e.code & 2);
                    io.AddKeyEvent(ImGuiMod_Alt, e.code & 4); io.AddKeyEvent(ImGuiMod_Super, e.code & 8); break;
            case 6: g_mx += e.x; g_my += e.y;   // integrate raw mouse delta -> absolute pos, clamp to screen
                    if (g_mx < 0) g_mx = 0; else if (g_mx > io.DisplaySize.x) g_mx = io.DisplaySize.x;
                    if (g_my < 0) g_my = 0; else if (g_my > io.DisplaySize.y) g_my = io.DisplaySize.y;
                    io.AddMousePosEvent(g_mx, g_my); break;
        }
    }
    g_queue.clear();
}

// macOS clipboard (NSPasteboard) so Cmd+V / Cmd+C work in the console input
static const char* clip_get(ImGuiContext*) {
    static std::string s;
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* str = [pb stringForType:NSPasteboardTypeString];
    s = (str != nil) ? std::string([str UTF8String]) : std::string();
    return s.c_str();
}
static void clip_set(ImGuiContext*, const char* text) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    if (text) [pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
}

// ============================================================================
// Lua runtime (PUC-Lua 5.1.5, interpreter-only) + the Game.* call bridge (Q6/Q7).
//   g_L is the persistent VM. `print` is redirected to the console. `Game.<method>(...)`
//   routes a request over a synchronous /tmp channel to hooks.js (which owns the RTTI
//   executor / callFunc) and returns the result, so Lua can call engine functions.
//   Q8 will add ImGui bindings + onDraw on top of this.
// ============================================================================
static lua_State* g_L = nullptr;
static unsigned g_luaSeq = 0;
static const char* LREQ_PATH = "/tmp/cp2077_lreq.txt";   // overlay -> hooks.js (Game call request)
static const char* LRES_PATH = "/tmp/cp2077_lres.txt";   // hooks.js -> overlay (result, seq-matched)

// print(...) -> the in-game console (Lua's stdout isn't visible in-game).
static int l_print(lua_State* L) {
    std::string out; int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        const char* s = lua_tostring(L, i);
        if (!s) s = lua_typename(L, lua_type(L, i));
        if (i > 1) out += "\t";
        out += (s ? s : "?");
    }
    appendOut(out.c_str());
    return 0;
}

// Game.<method>(args...). Native fast paths (non-blocking, safe in onDraw) are handled first; anything not
// yet ported falls back to the /tmp bridge -> hooks.js callFunc (blocking <=1.5s).
static int l_gameCall(lua_State* L) {
    const char* method = lua_tostring(L, lua_upvalueindex(1));
    if (!method) return luaL_error(L, "Game call: missing method name");
    // --- native fast path: the local player handle (the most common Game call) ---
    if (!strcmp(method,"GetPlayer") || !strcmp(method,"GetPlayerControlledGameObject") ||
        !strcmp(method,"GetLocalPlayerControlledGameObject")) {
        void* p = nccCachedPlayer();
        if (nccValidObject(p)) lua_pushnumber(L, (lua_Number)(uintptr_t)p); else lua_pushnil(L);
        return 1;
    }
    int nargs = lua_gettop(L);
    unsigned seq = ++g_luaSeq;
    std::string req = std::to_string(seq) + "\t" + method + "\t" + std::to_string(nargs);
    for (int i = 1; i <= nargs; i++) { const char* a = lua_tostring(L, i); req += "\t"; req += (a ? a : ""); }
    { FILE* f = fopen(LREQ_PATH, "w"); if (!f) return luaL_error(L, "Game.%s: cannot write request", method);
      fprintf(f, "%s\n", req.c_str()); fclose(f); }
    char type[32] = {0}; std::string value; bool got = false;
    for (int tries = 0; tries < 300 && !got; tries++) {      // 300 * 5ms = 1.5s timeout
        usleep(5000);
        FILE* r = fopen(LRES_PATH, "r"); if (!r) continue;
        char line[8192];
        while (fgets(line, sizeof(line), r)) {
            char* t1 = strchr(line, '\t'); if (!t1) continue;
            char* t2 = strchr(t1 + 1, '\t'); if (!t2) continue;
            *t1 = 0; *t2 = 0;
            if ((unsigned)strtoul(line, nullptr, 10) != seq) continue;
            strncpy(type, t1 + 1, sizeof(type) - 1);
            value = t2 + 1;
            size_t vn = value.size(); if (vn && value[vn-1] == '\n') value.erase(vn-1);
            got = true; break;
        }
        fclose(r);
    }
    if (!got) return luaL_error(L, "Game.%s: no response (hooks.js down, or not in-game?)", method);
    if (!strcmp(type, "ptr") || !strcmp(type, "int")) { lua_pushnumber(L, (lua_Number)strtoull(value.c_str(), nullptr, 0)); return 1; }
    if (!strcmp(type, "str"))  { lua_pushstring(L, value.c_str()); return 1; }
    if (!strcmp(type, "bool")) { lua_pushboolean(L, value == "true" || value == "1"); return 1; }
    if (!strcmp(type, "nil"))  { lua_pushnil(L); return 1; }
    if (!strcmp(type, "err"))  { return luaL_error(L, "Game.%s: %s", method, value.c_str()); }
    lua_pushnil(L); return 1;
}
// Game.<key> -> a closure bound to <key> that performs the bridged call.
static int l_game_index(lua_State* L) {
    lua_pushvalue(L, 2);                       // key (method name) becomes the closure upvalue
    lua_pushcclosure(L, l_gameCall, 1);
    return 1;
}
// nativeCall(class, method, ctx, ...args) -> typed result. ctx: "player" (native live handle), nil (static
// fn), or a number (raw object pointer). Args are marshalled by the function's declared param types. FULLY
// NATIVE: no /tmp, safe to call every frame from onDraw. Vector3/Vector4 returns expand to 3/4 numbers.
static int l_nativeCall(lua_State* L){
    const char* cls  = luaL_checkstring(L,1);
    const char* meth = luaL_checkstring(L,2);
    NccFn rf; if(!nccResolveFunc(cls,meth,&rf)) return luaL_error(L, "nativeCall: %s.%s not found", cls, meth);
    void* ctx;
    if(lua_isnoneornil(L,3)) ctx=nullptr;
    else if(lua_type(L,3)==LUA_TSTRING && !strcmp(lua_tostring(L,3),"player")) ctx=nccCachedPlayer();
    else ctx=(void*)(uintptr_t)lua_tonumber(L,3);
    // An instance method with a bad ctx would make the executor dereference garbage and HARD-crash (not a
    // catchable Lua error). Refuse here so mods can pcall it safely (e.g. when not in game / at a menu).
    if(!rf.isStatic && !nccValidObject(ctx)) return luaL_error(L, "nativeCall %s.%s: no valid object (not in game?)", cls, meth);
    int top=lua_gettop(L);
    std::vector<std::string> sargs; for(int i=4;i<=top;i++){ const char* s=lua_tostring(L,i); sargs.push_back(s?s:""); }
    std::vector<const char*> argv; for(auto& s:sargs) argv.push_back(s.c_str());
    uint8_t res[16]; std::string err;
    nccCall(&rf, ctx, (int)argv.size(), argv.empty()?nullptr:argv.data(), res, &err);
    if(!err.empty()) return luaL_error(L, "nativeCall %s.%s: %s", cls, meth, err.c_str());
    return nccPushResult(L, rf.retType, res);
}
// Game.playerPos() -> x, y, z  (3 numbers), or nil if not in game.
// RENDER-SAFE: this is meant for onDraw, so it NEVER raises a Lua error (no luaL_error / longjmp, which
// would corrupt the ImGui frame). On any failure it returns nil and the mod just checks `if x then`.
static int l_playerPos(lua_State* L){
    void* p = nccRenderPlayer();
    if(!nccValidObject(p)){ lua_pushnil(L); return 1; }
    static NccFn gw; static bool resolved=false, ok=false;
    if(!resolved){ const char* cls[]={"gameObject","gameEntity"}; ok=nccResolveAny(cls,2,"GetWorldPosition",&gw); resolved=true; }
    if(!ok){ lua_pushnil(L); return 1; }
    uint8_t r[16]; nccCallRaw(&gw, p, {}, r); const float* v=(const float*)r;
    lua_pushnumber(L,v[0]); lua_pushnumber(L,v[1]); lua_pushnumber(L,v[2]); return 3;
}

// ---- ImGui bindings for Lua (Q8): native + in-overlay, no channel, run at full framerate ----
static int g_igBeginDepth = 0;   // outstanding ImGui::Begin (each needs an End; unwound if a mod errors)
static int ig_Begin(lua_State* L){ const char* n=luaL_checkstring(L,1); bool open=true, r;
    if(lua_gettop(L)>=2 && !lua_isnil(L,2)){ open=lua_toboolean(L,2); r=ImGui::Begin(n,&open); } else { r=ImGui::Begin(n); }
    g_igBeginDepth++; lua_pushboolean(L,r); lua_pushboolean(L,open); return 2; }
static int ig_End(lua_State* L){ if(g_igBeginDepth>0){ ImGui::End(); g_igBeginDepth--; } return 0; }
static int ig_Text(lua_State* L){ ImGui::TextUnformatted(luaL_checkstring(L,1)); return 0; }
static int ig_TextColored(lua_State* L){ float r=(float)luaL_checknumber(L,1),g=(float)luaL_checknumber(L,2),b=(float)luaL_checknumber(L,3),a=(float)luaL_optnumber(L,4,1.0); ImGui::TextColored(ImVec4(r,g,b,a),"%s",luaL_checkstring(L,5)); return 0; }
static int ig_TextWrapped(lua_State* L){ ImGui::TextWrapped("%s",luaL_checkstring(L,1)); return 0; }
static int ig_Button(lua_State* L){ const char* lbl=luaL_checkstring(L,1); float w=(float)luaL_optnumber(L,2,0),h=(float)luaL_optnumber(L,3,0); lua_pushboolean(L,ImGui::Button(lbl,ImVec2(w,h))); return 1; }
static int ig_SmallButton(lua_State* L){ lua_pushboolean(L,ImGui::SmallButton(luaL_checkstring(L,1))); return 1; }
static int ig_Separator(lua_State* L){ ImGui::Separator(); return 0; }
static int ig_SameLine(lua_State* L){ ImGui::SameLine((float)luaL_optnumber(L,1,0)); return 0; }
static int ig_Spacing(lua_State* L){ ImGui::Spacing(); return 0; }
static int ig_Checkbox(lua_State* L){ const char* lbl=luaL_checkstring(L,1); bool v=lua_toboolean(L,2); bool c=ImGui::Checkbox(lbl,&v); lua_pushboolean(L,c); lua_pushboolean(L,v); return 2; }
static int ig_SliderInt(lua_State* L){ const char* lbl=luaL_checkstring(L,1); int v=(int)luaL_checknumber(L,2),mn=(int)luaL_checknumber(L,3),mx=(int)luaL_checknumber(L,4); bool c=ImGui::SliderInt(lbl,&v,mn,mx); lua_pushboolean(L,c); lua_pushnumber(L,v); return 2; }
static int ig_InputText(lua_State* L){ const char* lbl=luaL_checkstring(L,1); const char* cur=luaL_optstring(L,2,""); char buf[1024]; strncpy(buf,cur,sizeof(buf)-1); buf[sizeof(buf)-1]=0; bool c=ImGui::InputText(lbl,buf,sizeof(buf)); lua_pushboolean(L,c); lua_pushstring(L,buf); return 2; }
static int ig_SetNextWindowSize(lua_State* L){ ImGui::SetNextWindowSize(ImVec2((float)luaL_checknumber(L,1),(float)luaL_checknumber(L,2)), ImGuiCond_FirstUseEver); return 0; }

// registerForEvent("onDraw", fn): append fn to the onDraw registry (Q8 supports onDraw only).
static int l_registerForEvent(lua_State* L){
    const char* ev=luaL_checkstring(L,1); luaL_checktype(L,2,LUA_TFUNCTION);
    if(strcmp(ev,"onDraw")!=0) return 0;
    lua_getfield(L, LUA_REGISTRYINDEX, "ncc_onDraw");
    if(!lua_istable(L,-1)){ lua_pop(L,1); lua_newtable(L); lua_pushvalue(L,-1); lua_setfield(L, LUA_REGISTRYINDEX, "ncc_onDraw"); }
    int n=(int)lua_objlen(L,-1);
    lua_pushvalue(L,2); lua_rawseti(L,-2,n+1);
    lua_pop(L,1);
    return 0;
}
// Called every frame (inside the ImGui frame, when the overlay is shown). Each callback is pcall-wrapped,
// and any ImGui windows it left open (error or sloppy mod) are unwound so the frame stays balanced.
static void luaRunOnDraw(){
    if(!g_L) return;
    lua_getfield(g_L, LUA_REGISTRYINDEX, "ncc_onDraw");
    if(!lua_istable(g_L,-1)){ lua_pop(g_L,1); return; }
    int n=(int)lua_objlen(g_L,-1);
    for(int i=1;i<=n;i++){
        lua_rawgeti(g_L,-1,i);
        int depth0=g_igBeginDepth;
        if(lua_pcall(g_L,0,0,0)!=0){ appendOut((std::string("lua onDraw error: ")+lua_tostring(g_L,-1)).c_str()); lua_pop(g_L,1); }
        while(g_igBeginDepth>depth0){ ImGui::End(); g_igBeginDepth--; }
    }
    lua_pop(g_L,1);
}
// Load every overlayDir()/mods/<name>/init.lua (each calls registerForEvent to hook onDraw).
static void loadLuaMods(){
    if(!g_L) return;
    std::string dir = overlayDir() + "/mods";
    DIR* d = opendir(dir.c_str());
    if(!d){ olog("Lua: no mods dir at %s", dir.c_str()); return; }
    int loaded=0; struct dirent* e;
    while((e=readdir(d))!=nullptr){
        std::string name=e->d_name; if(name.empty()||name[0]=='.') continue;
        std::string init=dir+"/"+name+"/init.lua"; struct stat st; if(stat(init.c_str(),&st)!=0) continue;
        if(luaL_dofile(g_L, init.c_str())!=0){ const char* err=lua_tostring(g_L,-1); olog("Lua mod '%s' error: %s", name.c_str(), err?err:"?"); lua_pop(g_L,1); }
        else { loaded++; olog("Lua mod loaded: %s", name.c_str()); }
    }
    closedir(d);
    olog("Lua: %d mod(s) loaded from %s", loaded, dir.c_str());
}

static void initLua() {
    if (g_L) return;
    g_L = luaL_newstate();
    if (!g_L) { olog("Lua: luaL_newstate failed (out of memory?)"); return; }
    luaL_openlibs(g_L);                        // base, string, table, math, os, io, debug
    lua_pushcfunction(g_L, l_print); lua_setglobal(g_L, "print");
    lua_pushcfunction(g_L, l_registerForEvent); lua_setglobal(g_L, "registerForEvent");
    lua_pushcfunction(g_L, l_nativeCall); lua_setglobal(g_L, "nativeCall");   // Q12: non-blocking native engine call
    lua_newtable(g_L);                         // Game
    lua_newtable(g_L);                         // metatable
    lua_pushcfunction(g_L, l_game_index); lua_setfield(g_L, -2, "__index");
    lua_setmetatable(g_L, -2);
    lua_pushcfunction(g_L, l_playerPos); lua_setfield(g_L, -2, "playerPos");   // render-safe: returns nil, never errors
    lua_setglobal(g_L, "Game");
    lua_newtable(g_L);                         // ImGui
#define IGREG(nm,fn) do{ lua_pushcfunction(g_L,fn); lua_setfield(g_L,-2,nm); }while(0)
    IGREG("Begin",ig_Begin); IGREG("End",ig_End); IGREG("Text",ig_Text); IGREG("TextColored",ig_TextColored);
    IGREG("TextWrapped",ig_TextWrapped); IGREG("Button",ig_Button); IGREG("SmallButton",ig_SmallButton);
    IGREG("Separator",ig_Separator); IGREG("SameLine",ig_SameLine); IGREG("Spacing",ig_Spacing);
    IGREG("Checkbox",ig_Checkbox); IGREG("SliderInt",ig_SliderInt); IGREG("InputText",ig_InputText);
    IGREG("SetNextWindowSize",ig_SetNextWindowSize);
#undef IGREG
    lua_setglobal(g_L, "ImGui");
    if (luaL_dostring(g_L, "return _VERSION") == 0) {
        const char* v = lua_tostring(g_L, -1);
        olog("Lua initialized: %s + Game bridge + ImGui bindings", v ? v : "(unknown)");
        lua_pop(g_L, 1);
    } else { olog("Lua: smoke test failed: %s", lua_tostring(g_L, -1)); lua_pop(g_L, 1); }
    loadLuaMods();
}

// Run a console `lua <expr>` line: try as an expression (return ...) first, else as statements.
static void luaRunExpr(const char* expr) {
    if (!g_L) { appendOut("lua: VM not initialized (open the console once after launch)"); return; }
    int base0 = lua_gettop(g_L);
    std::string asRet = std::string("return ") + expr;
    if (luaL_loadstring(g_L, asRet.c_str()) != 0) {       // not an expression
        lua_pop(g_L, 1);
        if (luaL_loadstring(g_L, expr) != 0) { appendOut((std::string("lua error: ") + lua_tostring(g_L, -1)).c_str()); lua_settop(g_L, base0); return; }
    }
    if (lua_pcall(g_L, 0, LUA_MULTRET, 0) != 0) { appendOut((std::string("lua error: ") + lua_tostring(g_L, -1)).c_str()); lua_settop(g_L, base0); return; }
    if (lua_gettop(g_L) - base0 <= 0) { appendOut("lua: ok"); return; }
    for (int i = base0 + 1; i <= lua_gettop(g_L); i++) {
        const char* s = lua_tostring(g_L, i);
        if (!s) s = lua_typename(g_L, lua_type(g_L, i));
        appendOut((std::string("= ") + (s ? s : "?")).c_str());
    }
    lua_settop(g_L, base0);
}

static void initImGui(id<MTLDevice> dev) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigMacOSXBehaviors = true;   // Cmd-based shortcuts (Cmd+V paste, Cmd+C copy, Cmd+A select-all)
    io.MouseDrawCursor = true;         // draw our own cursor (the game hides the OS one during gameplay)
    ImGuiPlatformIO& pio = ImGui::GetPlatformIO();
    pio.Platform_GetClipboardTextFn = clip_get;
    pio.Platform_SetClipboardTextFn = clip_set;
    ImGui::StyleColorsDark();
    ImGui_ImplMetal_Init(dev);
    refreshOut();
    g_imguiInit = true;
    olog("ImGui %s initialized", IMGUI_VERSION);
    initLua();   // Q6: stand up the Lua runtime alongside ImGui
}

// Up/Down arrow command history for the input box.
static int inputCallback(ImGuiInputTextCallbackData* data) {
    if (data->EventFlag == ImGuiInputTextFlags_CallbackHistory) {
        int prev = g_historyPos;
        if (data->EventKey == ImGuiKey_UpArrow) {
            if (g_historyPos == -1) g_historyPos = (int)g_history.size() - 1;
            else if (g_historyPos > 0) g_historyPos--;
        } else if (data->EventKey == ImGuiKey_DownArrow) {
            if (g_historyPos != -1 && ++g_historyPos >= (int)g_history.size()) g_historyPos = -1;
        }
        if (prev != g_historyPos) {
            const char* s = (g_historyPos >= 0 && g_historyPos < (int)g_history.size()) ? g_history[g_historyPos].c_str() : "";
            data->DeleteChars(0, data->BufTextLen);
            data->InsertChars(0, s);
        }
    }
    return 0;
}

// ---- item catalog (searchable browser) ----
struct CatItem { std::string id, name, type, sheet; };
static std::vector<CatItem> g_catalog;
static bool g_catalogLoaded = false;
static char g_itemFilter[128] = {0};
static std::string g_lastFilter = "\x01";   // force first build
static std::vector<int> g_filtered;
static int g_giveQty = 1;

// item-browser category filter (by the catalog "sheet" column). index 0 = All.
struct Cat { const char* label; const char* sheet; };
static const Cat g_categories[] = {
    {"All", ""}, {"Weapons", "WEAPONS"}, {"Cyberware", "CYBERWARE"},
    {"Clothes", "CLOTHES"}, {"Crafting", "CRAFTING"}, {"Mods", "MODS"}, {"Misc", "MISC"}
};
static const int g_numCategories = 7;
static std::atomic<int>  g_catFilter{0};
static std::atomic<bool> g_catReq{false};

// the catalog ships next to the overlay dylib (red4ext/ when installed, build/ in dev)
static std::string overlayDir() {
    Dl_info info;
    if (dladdr((void*)&overlayDir, &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        size_t s = p.find_last_of('/');
        if (s != std::string::npos) return p.substr(0, s);
    }
    return ".";
}

static void loadCatalog() {
    g_catalogLoaded = true;
    std::string path = overlayDir() + "/cet_catalog.tsv";
    FILE* f = fopen(path.c_str(), "r");
    if (!f) { olog("catalog not found: %s", path.c_str()); return; }
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        std::string fields[4]; int fi = 0; std::string cur;
        for (char* p = line; ; ++p) {
            if (*p == '\t' || *p == 0) { if (fi < 4) fields[fi] = cur; fi++; cur.clear(); if (*p == 0) break; }
            else cur += *p;
        }
        if (fields[0].empty()) continue;
        g_catalog.push_back({fields[0], fields[1], fields[2], fields[3]});
    }
    fclose(f);
    olog("catalog loaded: %zu items", g_catalog.size());
}

static std::string lower(const std::string& s) { std::string r = s; for (auto& c : r) c = (char)tolower((unsigned char)c); return r; }

static void rebuildFilter() {
    g_filtered.clear();
    std::string q = lower(g_itemFilter);
    int cat = g_catFilter.load();
    const char* sheet = (cat > 0 && cat < g_numCategories) ? g_categories[cat].sheet : nullptr;
    for (int i = 0; i < (int)g_catalog.size(); ++i) {
        const CatItem& it = g_catalog[i];
        if (sheet && it.sheet != sheet) continue;   // category filter
        if (q.empty() || lower(it.name).find(q) != std::string::npos
                       || lower(it.id).find(q) != std::string::npos
                       || lower(it.type).find(q) != std::string::npos)
            g_filtered.push_back(i);
    }
    g_lastFilter = g_itemFilter;
}

// send a command to the game, echoing it into the console scrollback
static void runCommand(const std::string& cmd) {
    appendOut((std::string("> ") + cmd).c_str());
    submitCommand(cmd.c_str());
    refreshOut();
}

// last-action confirmation shown in the overlay footer
static std::string g_lastAction;
static void runLabeled(const std::string& cmd, const std::string& label) { g_lastAction = label; runCommand(cmd); }

// persistent pinned-favorite items (~/Library/Application Support/NightCityConsole/favorites.txt)
struct Fav { std::string id, name; };
static std::vector<Fav> g_favorites;
static bool g_favLoaded = false;

static std::string favPath() {
    NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/NightCityConsole"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return std::string([[dir stringByAppendingPathComponent:@"favorites.txt"] UTF8String]);
}
static void loadFavorites() {
    g_favLoaded = true;
    FILE* f = fopen(favPath().c_str(), "r"); if (!f) return;
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        size_t n = strlen(line); while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        if (!line[0]) continue;
        char* tab = strchr(line, '\t');
        if (tab) { *tab = 0; g_favorites.push_back({line, tab + 1}); }
        else g_favorites.push_back({line, line});
    }
    fclose(f);
}
static void saveFavorites() {
    FILE* f = fopen(favPath().c_str(), "w"); if (!f) return;
    for (auto& fv : g_favorites) fprintf(f, "%s\t%s\n", fv.id.c_str(), fv.name.c_str());
    fclose(f);
}
static void addFavorite(const std::string& id, const std::string& name) {
    for (auto& fv : g_favorites) if (fv.id == id) { g_lastAction = "Already pinned: " + name; return; }
    g_favorites.push_back({id, name}); saveFavorites(); g_lastAction = "Pinned: " + name;
}
static void removeFavorite(int i) {
    if (i >= 0 && i < (int)g_favorites.size()) { g_favorites.erase(g_favorites.begin() + i); saveFavorites(); }
}

static void drawItemsTab() {
    if (!g_catalogLoaded) loadCatalog();
    if (g_catalog.empty()) { ImGui::TextDisabled("Item catalog not found (cet_catalog.tsv)."); return; }
    // category row: click a category to browse it (or Cmd+G to cycle by keyboard)
    int cat = g_catFilter.load();
    for (int c = 0; c < g_numCategories; ++c) {
        if (c) ImGui::SameLine();
        bool active = (c == cat);
        if (active) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.20f, 0.45f, 0.75f, 1.0f));
        if (ImGui::SmallButton(g_categories[c].label)) { g_catFilter = c; g_catReq = true; }
        if (active) ImGui::PopStyleColor();
    }
    ImGui::SetNextItemWidth(110);
    if (ImGui::InputInt("qty", &g_giveQty)) { if (g_giveQty < 1) g_giveQty = 1; }
    ImGui::SameLine();
    if (g_itemsTabEntered.exchange(false)) ImGui::SetKeyboardFocusHere();   // focus the search box on tab enter
    ImGui::SetNextItemWidth(-1);
    bool entered = ImGui::InputTextWithHint("##itemsearch", "type to search, Enter spawns the top result (Cmd+G cycles category)",
                                            g_itemFilter, sizeof(g_itemFilter), ImGuiInputTextFlags_EnterReturnsTrue);
    if (g_catReq.exchange(false) || g_lastFilter != g_itemFilter) rebuildFilter();
    if (entered && !g_filtered.empty()) {
        const CatItem& top = g_catalog[g_filtered[0]];
        runLabeled("give " + top.id + " " + std::to_string(g_giveQty), "Added " + top.name);
        ImGui::SetKeyboardFocusHere(-1);   // keep typing in the search box
    }
    if (g_pinTopReq.exchange(false) && !g_filtered.empty()) {   // Cmd+P pins the top result
        const CatItem& top = g_catalog[g_filtered[0]];
        addFavorite(top.id, top.name);
    }
    if (!g_filtered.empty())
        ImGui::TextDisabled("Enter spawns / Cmd+P pins: %s   (%d matches)", g_catalog[g_filtered[0]].name.c_str(), (int)g_filtered.size());
    else
        ImGui::TextDisabled("no matches");
    ImGui::Separator();
    ImGui::BeginChild("itemlist", ImVec2(0, 0));
    ImGuiListClipper clipper; clipper.Begin((int)g_filtered.size());
    while (clipper.Step()) {
        for (int row = clipper.DisplayStart; row < clipper.DisplayEnd; ++row) {
            const CatItem& it = g_catalog[g_filtered[row]];
            ImGui::PushID(row);
            if (ImGui::SmallButton("Give")) runLabeled("give " + it.id + " " + std::to_string(g_giveQty), "Added " + it.name);
            ImGui::SameLine();
            if (ImGui::SmallButton("Pin")) addFavorite(it.id, it.name);
            ImGui::SameLine();
            if (row == 0) ImGui::TextColored(ImVec4(1.0f, 0.95f, 0.4f, 1.0f), "%s", it.name.c_str());  // top result (Enter target)
            else ImGui::TextUnformatted(it.name.c_str());
            ImGui::SameLine(); ImGui::TextDisabled("  %s", it.id.c_str());
            ImGui::PopID();
        }
    }
    ImGui::EndChild();
}

static void drawQuickTab() {
    if (!g_favLoaded) loadFavorites();
    ImGui::TextDisabled("Pinned items:");
    if (g_favorites.empty())
        ImGui::TextDisabled("  (none yet - go to the Items tab, find an item, click Pin)");
    for (int i = 0; i < (int)g_favorites.size(); ++i) {
        ImGui::PushID(2000 + i);
        if (ImGui::SmallButton("Give")) runLabeled("give " + g_favorites[i].id + " 1", "Added " + g_favorites[i].name);
        ImGui::SameLine();
        if (ImGui::SmallButton("x")) { removeFavorite(i); ImGui::PopID(); break; }
        ImGui::SameLine(); ImGui::TextUnformatted(g_favorites[i].name.c_str());
        ImGui::PopID();
    }
    ImGui::Separator();
    ImGui::TextDisabled("One-click cheats:");
    if (ImGui::Button("Money +50k")) runLabeled("money 50000", "Money +50k"); ImGui::SameLine();
    if (ImGui::Button("Heal")) runLabeled("heal", "Healed"); ImGui::SameLine();
    if (ImGui::Button("Godmode")) runLabeled("godmode", "Godmode on"); ImGui::SameLine();
    if (ImGui::Button("Godmode off")) runLabeled("godmode off", "Godmode off");
    if (ImGui::Button("Invisible")) runLabeled("invis", "Invisible on"); ImGui::SameLine();
    if (ImGui::Button("Invisible off")) runLabeled("invis off", "Invisible off"); ImGui::SameLine();
    if (ImGui::Button("Infinite ammo")) runLabeled("infammo", "Infinite ammo on"); ImGui::SameLine();
    if (ImGui::Button("Ammo off")) runLabeled("infammo off", "Infinite ammo off");
    if (ImGui::Button("Perks +10")) runLabeled("perks 10", "Perks +10"); ImGui::SameLine();
    if (ImGui::Button("Attrs +10")) runLabeled("attrs 10", "Attrs +10"); ImGui::SameLine();
    if (ImGui::Button("Relic +10")) runLabeled("relic 10", "Relic +10"); ImGui::SameLine();
    if (ImGui::Button("Level 50")) runLabeled("level 50", "Level 50"); ImGui::SameLine();
    if (ImGui::Button("Street Cred 50")) runLabeled("streetcred 50", "Street Cred 50");
    ImGui::Separator();
    ImGui::TextDisabled("World:");
    if (ImGui::Button("Day")) runLabeled("time 12", "Time: noon"); ImGui::SameLine();
    if (ImGui::Button("Night")) runLabeled("time 0", "Time: midnight");
    if (ImGui::Button("Slow-mo")) runLabeled("slowmo", "Slow-mo on"); ImGui::SameLine();
    if (ImGui::Button("Slow-mo off")) runLabeled("slowmo off", "Slow-mo off"); ImGui::SameLine();
    if (ImGui::Button("No police")) runLabeled("nopolice", "Police disabled"); ImGui::SameLine();
    if (ImGui::Button("Police on")) runLabeled("nopolice off", "Police enabled");
    ImGui::Separator();
    ImGui::TextDisabled("Teleport bookmark (save a spot, return later):");
    static char tpname[64] = "home";
    ImGui::SetNextItemWidth(160); ImGui::InputText("##tpname", tpname, sizeof(tpname));
    ImGui::SameLine(); if (ImGui::Button("Save spot")) runLabeled(std::string("teleport save ") + tpname, std::string("Saved spot: ") + tpname);
    ImGui::SameLine(); if (ImGui::Button("Go to spot")) runLabeled(std::string("teleport ") + tpname, std::string("Teleported: ") + tpname);
}

// ---- Creator: build a custom iconic weapon IN-PROCESS (ported from makeweapon.py). No Python, no
//      external scripts, no hardcoded paths: generates the TweakXL YAML + appends the name/flavor/gold
//      LocKey strings, then applies live via cmnreload/tweakload/give. Game dir discovered at runtime. ----
#define CR_SLOT_RANGED "AttachmentSlots.IconicWeaponModLegendary"
#define CR_SLOT_MELEE  "AttachmentSlots.IconicMeleeWeaponMod1"
#define CR_BP_R   "Items.Iconic_Ranged_Weapon_Blueprint"
#define CR_BP_RN  "Items.Iconic_Ranged_Weapon_NoMuzzle_Blueprint"
#define CR_BP_RA  "Items.Iconic_Ranged_Weapon_NoAttachments_Blueprint"
#define CR_BP_M   "Items.Iconic_Melee_Blueprint"
static const long CR_LOCKEY_START = 7777798;

struct CrBase { const char* label; const char* preset; const char* bp; const char* slot; bool melee; };
static const CrBase kCrBases[] = {
    {"Pistol  -  Lexington", "Items.Preset_Lexington_Default",    CR_BP_R,  CR_SLOT_RANGED, false},
    {"SMG  -  Saratoga",     "Items.Preset_Saratoga_Default",     CR_BP_R,  CR_SLOT_RANGED, false},
    {"Shotgun  -  Carnage",  "Items.Preset_Carnage_Default",      CR_BP_RA, CR_SLOT_RANGED, false},
    {"Sniper  -  Nekomata",  "Items.Preset_Nekomata_Default",     CR_BP_RN, CR_SLOT_RANGED, false},
    {"Katana",               "Items.Preset_Katana_Default",       CR_BP_M,  CR_SLOT_MELEE,  true},
    {"Knife",                "Items.Preset_Knife_Default",        CR_BP_M,  CR_SLOT_MELEE,  true},
    {"Baseball Bat",         "Items.Preset_Baseball_Bat_Default", CR_BP_M,  CR_SLOT_MELEE,  true},
};
static const int kCrNumBases = (int)(sizeof(kCrBases) / sizeof(kCrBases[0]));

struct CrStat { const char* stat; const char* mod; const char* val; };
struct CrEff  { const char* name; CrStat stats[2]; int nstats; bool meleeOnly; };
static const CrEff kCrEffects[] = {
    {"fire",        {{"BurningApplicationRate","Additive","100"}}, 1, false},
    {"bleed",       {{"BleedingApplicationRate","Additive","75"}}, 1, false},
    {"shock",       {{"ElectrocutedApplicationRate","Additive","75"}}, 1, false},
    {"poison",      {{"PoisonedApplicationRate","Additive","75"}}, 1, false},
    {"stun",        {{"StunApplicationRate","Additive","75"}}, 1, false},
    {"crit",        {{"CritChance","Additive","40"},{"CritDamage","Additive","150"}}, 2, false},
    {"headshot",    {{"HeadshotDamageMultiplier","Additive","3.0"}}, 1, false},
    {"ignorearmor", {{"CanWeaponIgnoreArmor","Additive","1"}}, 1, false},
    {"armorpen",    {{"ArmorPenetrationBonus","Additive","100"}}, 1, false},
    {"lifesteal",   {{"HealthRegainOnKill","Additive","30"}}, 1, false},
    {"execute",     {{"BonusPercentDamageToEnemiesBelowHalfHealth","Additive","50"}}, 1, false},
    {"damage",      {{"DamagePerHit","Multiplier","1.5"}}, 1, false},
    {"bigmag",      {{"MagazineCapacityBonus","Additive","40"}}, 1, false},
    {"fastreload",  {{"ReloadSpeedPercentBonus","Additive","50"}}, 1, false},
    {"stealth",     {{"StealthHitDamageBonus","Additive","100"}}, 1, false},
    {"melee",       {{"MeleeDamagePercentBonus","Additive","60"}}, 1, false},
    {"antiboss",    {{"BonusDamageAgainstBosses","Additive","100"}}, 1, false},
    {"leap",        {{"CanMeleeLeap","Additive","1"}}, 1, true},
};
static const int kCrNumEffects = (int)(sizeof(kCrEffects) / sizeof(kCrEffects[0]));

static int   g_crBase = 0;
static char  g_crName[64]   = "Crit Machine";
static char  g_crWhite[256] = "Built in a back-alley ripperdoc's. One of a kind.";
static char  g_crGold[256]  = "Custom iconic ability.";
static bool  g_crEff[32] = { false };
static std::mutex g_crMtx;
static std::string g_crStatus;
static std::atomic<bool> g_crBusy{false};

// Game dir = the folder two levels up from this dylib (<GAME>/red4ext/libcyberconsole_overlay.dylib).
static std::string crGameRoot() {
    Dl_info info;
    if (dladdr((void*)&crGameRoot, &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        size_t a = p.find_last_of('/'); if (a != std::string::npos) p.resize(a);   // -> <GAME>/red4ext
        size_t b = p.find_last_of('/'); if (b != std::string::npos) p.resize(b);   // -> <GAME>
        return p;
    }
    return "";
}
static std::string crJsonEsc(const std::string& s) {
    std::string o; for (unsigned char c : s) { switch (c) {
        case '"': o += "\\\""; break; case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break; case '\r': o += "\\r"; break; case '\t': o += "\\t"; break;
        default: if (c < 0x20) { char b[8]; snprintf(b, sizeof(b), "\\u%04x", c); o += b; } else o += (char)c; }
    } return o;
}
// Mirror Python str.title() + strip non-alnum, then prefix CyberModMan.
static std::string crRecordStem(const std::string& name) {
    std::string out; bool wordStart = true;
    for (char c : name) {
        if (isalnum((unsigned char)c)) {
            if (isalpha((unsigned char)c)) { out += (char)(wordStart ? toupper(c) : tolower(c)); wordStart = false; }
            else { out += c; wordStart = true; }
        } else wordStart = true;
    }
    return "CyberModMan" + (out.empty() ? std::string("Weapon") : out);
}
static std::string crStatYaml(const char* st, const char* mt, const char* v) {
    return std::string("    - $type: ConstantStatModifier\n      statType: BaseStats.") + st +
           "\n      modifierType: " + mt + "\n      value: " + v + "\n";
}
static std::string crReadFile(const std::string& path) {
    std::string c; FILE* f = fopen(path.c_str(), "r"); if (!f) return c;
    char b[4096]; size_t n; while ((n = fread(b,1,sizeof(b),f)) > 0) c.append(b,n); fclose(f); return c;
}
static std::set<long> crUsedLockeys(const std::string& path) {
    std::set<long> used; std::string c = crReadFile(path);
    for (size_t i = 0; i < c.size(); ) {
        if (c[i] == '"') { size_t j = i+1; std::string num; bool digits = true;
            while (j < c.size() && c[j] != '"') { if (!isdigit((unsigned char)c[j])) digits = false; num += c[j]; j++; }
            if (digits && !num.empty() && j < c.size()) { size_t k = j+1;
                while (k < c.size() && isspace((unsigned char)c[k])) k++;
                if (k < c.size() && c[k] == ':') used.insert(strtol(num.c_str(), nullptr, 10)); }
            i = j + 1;
        } else i++;
    }
    return used;
}
static bool crAppendNames(const std::string& path, long k1, const std::string& v1,
                          long k2, const std::string& v2, long k3, const std::string& v3) {
    std::string c = crReadFile(path);
    while (!c.empty() && isspace((unsigned char)c.back())) c.pop_back();
    std::string entries =
        "  \"" + std::to_string(k1) + "\": \"" + crJsonEsc(v1) + "\",\n"
        "  \"" + std::to_string(k2) + "\": \"" + crJsonEsc(v2) + "\",\n"
        "  \"" + std::to_string(k3) + "\": \"" + crJsonEsc(v3) + "\"\n";
    std::string out;
    if (c.empty() || c == "{}" || c == "{") out = "{\n" + entries + "}\n";
    else if (c.back() == '}') {
        c.pop_back(); while (!c.empty() && isspace((unsigned char)c.back())) c.pop_back();
        std::string sep = (!c.empty() && c.back() == '{') ? "\n" : ",\n";
        out = c + sep + entries + "}\n";
    } else out = "{\n" + entries + "}\n";
    FILE* w = fopen(path.c_str(), "w"); if (!w) return false;
    fwrite(out.data(), 1, out.size(), w); fclose(w); return true;
}
// Generate + deploy. Returns the record id, or "" with err set.
static std::string crGenWeapon(int baseIdx, const std::string& name, const std::string& white,
                               const std::string& gold, const bool* effSel, std::string& err) {
    std::string game = crGameRoot();
    if (game.empty()) { err = "could not locate game dir"; return ""; }
    std::string tweaks = game + "/r6/tweaks";
    std::string namesPath = game + "/red4ext/cybermodman_names.json";
    const CrBase& bse = kCrBases[baseIdx];
    std::string stem = crRecordStem(name);
    std::string recordId = "Items." + stem;

    std::string body; bool hasDamage = false;
    for (int i = 0; i < kCrNumEffects; ++i) {
        if (!effSel[i]) continue;
        const CrEff& e = kCrEffects[i];
        if (e.meleeOnly && !bse.melee) continue;
        for (int s = 0; s < e.nstats; ++s) {
            body += crStatYaml(e.stats[s].stat, e.stats[s].mod, e.stats[s].val);
            if (std::string(e.stats[s].stat) == "DamagePerHit") hasDamage = true;
        }
    }
    std::string stats = (hasDamage ? std::string() : crStatYaml("DamagePerHit","Multiplier","1.5")) + body;

    std::set<long> used = crUsedLockeys(namesPath);
    long keys[3]; int got = 0; for (long k = CR_LOCKEY_START; got < 3; ++k) if (!used.count(k)) keys[got++] = k;
    std::string kn = std::to_string(keys[0]), kw = std::to_string(keys[1]), kg = std::to_string(keys[2]);

    std::string yaml =
        "# cybermodman generated iconic: " + name + "\n" +
        "Items." + stem + "_AbilityUI:\n  $type: GameplayLogicPackageUIData\n  localizedDescription: LocKey#" + kg + "\n\n" +
        "Items." + stem + "_Ability:\n  $base: Items.IconicWeaponModAbilityBase\n  UIData: Items." + stem + "_AbilityUI\n\n" +
        "Items." + stem + "_Mod:\n  $base: Items.IconicWeaponModBase\n  OnAttach:\n    - Items." + stem + "_Ability\n  statModifiers:\n" +
        stats +
        "Items." + stem + ":\n  $base: " + bse.preset + "\n  blueprint: " + bse.bp + "\n  quality: Quality.Legendary\n" +
        "  displayName: LocKey#" + kn + "\n  gameplayDescription: LocKey#" + kw + "\n" +
        "  tags:\n    - !append IconicWeapon\n  statModifiers:\n    - !append Quality.IconicItem\n" +
        "  statModifierGroups:\n    - !remove Items.QualityRandomization\n    - !append Items.IconicQualityRandomization\n" +
        "  slotPartListPreset:\n    - !append-once\n      $type: SlotItemPartPreset\n      itemPartPreset: Items." + stem + "_Mod\n      slot: " + bse.slot + "\n";

    std::string yamlPath = tweaks + "/cybermodman_" + stem + ".yaml";
    FILE* yf = fopen(yamlPath.c_str(), "w");
    if (!yf) { err = "cannot write " + yamlPath; return ""; }
    fwrite(yaml.data(), 1, yaml.size(), yf); fclose(yf);
    if (!crAppendNames(namesPath, keys[0], name, keys[1], white, keys[2], gold)) { err = "cannot write names json"; return ""; }
    return recordId;
}

static void crSetStatus(const std::string& s) { std::lock_guard<std::mutex> lk(g_crMtx); g_crStatus = s; }

static void crCreateThread(int baseIdx, std::string name, std::string white, std::string gold, std::vector<char> sel) {
    g_crBusy = true;
    crSetStatus("Generating \"" + name + "\" ...");
    bool eff[64] = { false }; for (size_t i = 0; i < sel.size() && i < 64; ++i) eff[i] = sel[i] != 0;
    std::string err;
    std::string recordId = crGenWeapon(baseIdx, name, white, gold, eff, err);
    if (recordId.empty()) { crSetStatus("FAILED: " + err); g_crBusy = false; return; }
    crSetStatus("Created " + recordId + " - applying in-game ...");
    runCommand("cmnreload");               usleep(350000);   // load the new name/flavor/gold LocKeys
    runCommand("tweakload");               usleep(750000);   // apply the new weapon record to TweakDB
    runCommand("give " + recordId + " 1"); usleep(150000);   // hand it to the player
    crSetStatus("DONE: \"" + name + "\" (" + recordId + ") created + applied + added to inventory.\n"
                "Note: the GOLD ability text fully links after one game restart (name, white text + the weapon work now).");
    g_crBusy = false;
}

static void drawCreatorTab() {
    ImGui::TextColored(ImVec4(1.0f, 0.84f, 0.0f, 1.0f), "CYBERMODMAN  -  Custom Iconic Weapon Creator");
    ImGui::TextDisabled("Pick a base, name it, choose effects, hit Create. (Load a save first so it can be given.)");
    ImGui::Separator();
    ImGui::SetNextItemWidth(300);
    if (ImGui::BeginCombo("Base", kCrBases[g_crBase].label)) {
        for (int i = 0; i < kCrNumBases; ++i) { bool sel = (i == g_crBase);
            if (ImGui::Selectable(kCrBases[i].label, sel)) g_crBase = i;
            if (sel) ImGui::SetItemDefaultFocus(); }
        ImGui::EndCombo();
    }
    ImGui::SetNextItemWidth(300); ImGui::InputText("Name", g_crName, sizeof(g_crName));
    ImGui::SetNextItemWidth(520); ImGui::InputText("White flavor", g_crWhite, sizeof(g_crWhite));
    ImGui::SetNextItemWidth(520); ImGui::InputText("Gold ability text", g_crGold, sizeof(g_crGold));
    ImGui::Separator();
    ImGui::TextDisabled("Effects (leap = melee only):");
    for (int i = 0; i < kCrNumEffects; ++i) {
        ImGui::Checkbox(kCrEffects[i].name, &g_crEff[i]);
        if ((i % 6) != 5 && i != kCrNumEffects - 1) ImGui::SameLine();
    }
    ImGui::Separator();
    bool busy = g_crBusy.load();
    if (busy) ImGui::BeginDisabled();
    if (ImGui::Button("Create & Apply", ImVec2(190, 34))) {
        std::vector<char> sel(kCrNumEffects); for (int i = 0; i < kCrNumEffects; ++i) sel[i] = g_crEff[i] ? 1 : 0;
        std::thread(crCreateThread, g_crBase, std::string(g_crName),
                    std::string(g_crWhite), std::string(g_crGold), sel).detach();
    }
    if (busy) { ImGui::EndDisabled(); ImGui::SameLine(); ImGui::TextDisabled("working..."); }
    { std::lock_guard<std::mutex> lk(g_crMtx);
      if (!g_crStatus.empty()) { ImGui::Separator(); ImGui::TextWrapped("%s", g_crStatus.c_str()); } }
}

// ============================================================================
// MODS TAB - loose .archive mod manager for <GAME>/archive/Mac/mod
//   The runtime (red4ext_hooks.js installModFolderLoader) registers a Mod-scope(4)
//   ArchiveSet for archive/mac/mod at ResourceDepot::InitializeArchives and loads
//   every *.archive in it via the engine's own Append+LoadArchives. This tab is the
//   front end: list / enable / disable (rename .archive <-> .archive.off) / open
//   the folder. Archives load at startup, so changes apply on the next game RESTART.
// ============================================================================
struct ModEntry { std::string display; std::string filename; bool enabled; long sizeKB; };
static std::vector<ModEntry> g_mods;
static std::string g_modsStatus;
static bool g_modsScanned = false;

static std::string modsDir() {
    std::string g = crGameRoot();
    return g.empty() ? "" : g + "/archive/Mac/mod";
}
static bool strEndsWith(const std::string& s, const std::string& suf) {
    return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}
// Scan the mod dir for *.archive (enabled) and *.archive.off (disabled). Cheap
// (names + stat only), so it runs synchronously on the render thread.
static void modsScan() {
    std::vector<ModEntry> found;
    std::string dir = modsDir();
    DIR* d = dir.empty() ? nullptr : opendir(dir.c_str());
    if (d) {
        struct dirent* e;
        while ((e = readdir(d)) != nullptr) {
            std::string n = e->d_name;
            if (n.empty() || n[0] == '.') continue;                 // skip dotfiles / . / ..
            bool disabled = strEndsWith(n, ".archive.off");
            bool enabled  = !disabled && strEndsWith(n, ".archive");
            if (!enabled && !disabled) continue;
            ModEntry m; m.filename = n; m.enabled = enabled;
            m.display = n.substr(0, n.size() - (disabled ? 12 : 8)); // strip .archive.off / .archive
            struct stat st; m.sizeKB = (stat((dir + "/" + n).c_str(), &st) == 0) ? (long)(st.st_size / 1024) : 0;
            found.push_back(m);
        }
        closedir(d);
    }
    std::sort(found.begin(), found.end(), [](const ModEntry& a, const ModEntry& b) { return a.display < b.display; });
    g_mods = found; g_modsScanned = true;
}
// Toggle = rename .archive <-> .archive.off. By value: modsScan() below reassigns g_mods.
static void modsToggle(ModEntry m) {
    std::string dir = modsDir();
    std::string from = dir + "/" + m.filename;
    std::string to   = dir + "/" + m.display + (m.enabled ? ".archive.off" : ".archive");
    if (rename(from.c_str(), to.c_str()) == 0)
        g_modsStatus = std::string(m.enabled ? "Disabled \"" : "Enabled \"") + m.display + "\"  -  restart the game to apply.";
    else
        g_modsStatus = "FAILED to toggle \"" + m.display + "\" (rename error).";
    modsScan();
}
static void modsOpenFolder() {
    std::string dir = modsDir();
    if (dir.empty()) return;
    mkdir(dir.c_str(), 0755);                                        // ensure it exists
    @autoreleasepool {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:dir.c_str()] isDirectory:YES]];
    }
}
static void drawModsTab() {
    ImGui::TextColored(ImVec4(1.0f, 0.84f, 0.0f, 1.0f), "NIGHT CITY CONSOLE  -  Loose Mod Manager");
    ImGui::TextDisabled("Drop any .archive into the folder, Enable it, restart. Loads like the Windows mod/ folder.");
    std::string dir = modsDir();
    if (dir.empty()) { ImGui::TextColored(ImVec4(1, 0.4f, 0.4f, 1), "Could not locate the game folder."); return; }
    ImGui::TextWrapped("Folder: %s", dir.c_str());
    ImGui::Separator();
    if (!g_modsScanned) modsScan();
    if (ImGui::Button("Refresh")) modsScan();
    ImGui::SameLine();
    if (ImGui::Button("Open folder in Finder")) modsOpenFolder();
    ImGui::SameLine();
    if (ImGui::Button("Create folder")) { mkdir(dir.c_str(), 0755); modsScan(); g_modsStatus = "Mod folder ready."; }
    ImGui::Separator();
    int enabledCount = 0; for (auto& m : g_mods) if (m.enabled) enabledCount++;
    ImGui::Text("%d mod%s found, %d enabled", (int)g_mods.size(), g_mods.size() == 1 ? "" : "s", enabledCount);
    int toggleIdx = -1;
    if (g_mods.empty()) {
        ImGui::Spacing();
        ImGui::TextDisabled("No mods yet. Click \"Open folder in Finder\", drop in .archive files, then Refresh.");
    } else {
        ImGui::BeginChild("modlist", ImVec2(0, 300), true);
        for (int i = 0; i < (int)g_mods.size(); ++i) {
            const ModEntry& m = g_mods[i];
            ImGui::PushID(i);
            if (m.enabled) ImGui::TextColored(ImVec4(0.30f, 0.90f, 0.40f, 1.0f), "[ON ]");
            else           ImGui::TextColored(ImVec4(0.60f, 0.60f, 0.60f, 1.0f), "[off]");
            ImGui::SameLine(); ImGui::Text("%s", m.display.c_str());
            ImGui::SameLine(); ImGui::TextDisabled("(%ld KB)", m.sizeKB);
            ImGui::SameLine(ImGui::GetWindowWidth() - 100);
            if (ImGui::Button(m.enabled ? "Disable" : "Enable", ImVec2(84, 0))) toggleIdx = i;
            ImGui::PopID();
        }
        ImGui::EndChild();
    }
    if (toggleIdx >= 0) modsToggle(g_mods[toggleIdx]);
    if (!g_modsStatus.empty()) { ImGui::Separator(); ImGui::TextWrapped("%s", g_modsStatus.c_str()); }
}

// ============================================================================
// DECLARATIVE TAB ENGINE
//   Tabs are JSON files describing widgets. A button's "cmd" is run through the
//   EXISTING runLabeled(subst(cmd), toast) -> submitCommand pipeline, so every
//   verb the console already understands keeps working unchanged. New "features"
//   become a JSON file dropped in tabs/ (ships) or ~/Library/Application
//   Support/NightCityConsole/tabs/ (user override), hot-reloaded once/sec.
// ============================================================================
enum WKind {
    WK_BUTTON = 0, WK_CHECKBOX, WK_SLIDER_INT, WK_INPUT_TEXT,
    WK_SEPARATOR, WK_SAME_LINE, WK_TEXT
};
struct Widget {
    WKind kind = WK_TEXT;
    std::string label;     // visible label / text
    std::string cmd;       // command template for buttons (button only); {field} placeholders substituted
    std::string field;     // state key for checkbox / slider_int / input_text
    std::string cmdOn;     // checkbox: command when toggled on
    std::string cmdOff;    // checkbox: command when toggled off
    std::string toast;     // footer confirmation label (defaults to label)
    int imin = 0, imax = 100;  // slider_int bounds
    int idef = 0;          // slider_int / default int
    std::string sdef;      // input_text default
};
struct Tab {
    std::string id;        // stable id (filename stem unless overridden); app-support overrides by id
    std::string title;     // tab caption
    bool builtin = false;  // true -> nativeDraw renders it
    void (*nativeDraw)() = nullptr;   // builtin draw fn (Console handled specially)
    std::string nativeKind;           // "console" | "items" | "quick" | "creator" | "" (data tab)
    std::vector<Widget> widgets;       // data-tab widgets
    std::string sourcePath;            // file this tab came from (for mtime polling)
};
static std::vector<Tab> g_tabs;
static std::unordered_map<std::string, std::string> g_fieldStr;   // input_text state
static std::unordered_map<std::string, int>         g_fieldInt;   // checkbox(0/1) + slider_int state
static std::mutex g_tabsMtx;
// g_tabsDirty is declared up top (near the command-channel globals) so handleSubmit's
// `reload` verb can set it before the tab engine is defined.
static int g_numTabs = 0;

// Substitute {field} placeholders in a command template with current tab state.
// {field} pulls from g_fieldStr first, then g_fieldInt (rendered as integer).
static std::string subst(const std::string& tmpl) {
    std::string out; out.reserve(tmpl.size());
    for (size_t i = 0; i < tmpl.size(); ) {
        if (tmpl[i] == '{') {
            size_t j = tmpl.find('}', i + 1);
            if (j != std::string::npos) {
                std::string key = tmpl.substr(i + 1, j - i - 1);
                auto si = g_fieldStr.find(key);
                if (si != g_fieldStr.end()) out += si->second;
                else { auto ii = g_fieldInt.find(key); if (ii != g_fieldInt.end()) out += std::to_string(ii->second); }
                i = j + 1; continue;
            }
        }
        out += tmpl[i++];
    }
    return out;
}

// Forward decls for the builtin native tab bodies (defined below / above).
static void drawConsoleInner(int req, int myTab);

// Render a declarative data tab: walk its widgets to ImGui. Buttons route every
// command through the existing runLabeled(subst(cmd), toast) pipeline.
static void drawDataTab(const Tab& t) {
    int wid = 0;
    for (const Widget& w : t.widgets) {
        ImGui::PushID(wid++);
        switch (w.kind) {
            case WK_TEXT:
                ImGui::TextWrapped("%s", w.label.c_str());
                break;
            case WK_SEPARATOR:
                ImGui::Separator();
                break;
            case WK_SAME_LINE:
                ImGui::SameLine();
                break;
            case WK_BUTTON:
                if (ImGui::Button(w.label.c_str())) {
                    std::string toast = w.toast.empty() ? w.label : w.toast;
                    runLabeled(subst(w.cmd), toast);
                }
                break;
            case WK_CHECKBOX: {
                int& st = g_fieldInt[w.field];
                bool b = st != 0;
                if (ImGui::Checkbox(w.label.c_str(), &b)) {
                    st = b ? 1 : 0;
                    const std::string& c = b ? w.cmdOn : w.cmdOff;
                    if (!c.empty()) {
                        std::string toast = (w.toast.empty() ? w.label : w.toast) + (b ? " on" : " off");
                        runLabeled(subst(c), toast);
                    }
                }
                break;
            }
            case WK_SLIDER_INT: {
                auto it = g_fieldInt.find(w.field);
                if (it == g_fieldInt.end()) { g_fieldInt[w.field] = w.idef; it = g_fieldInt.find(w.field); }
                int v = it->second;
                if (ImGui::SliderInt(w.label.c_str(), &v, w.imin, w.imax)) g_fieldInt[w.field] = v;
                break;
            }
            case WK_INPUT_TEXT: {
                auto it = g_fieldStr.find(w.field);
                if (it == g_fieldStr.end()) { g_fieldStr[w.field] = w.sdef; it = g_fieldStr.find(w.field); }
                char buf[512];
                snprintf(buf, sizeof(buf), "%s", it->second.c_str());
                if (ImGui::InputText(w.label.c_str(), buf, sizeof(buf))) g_fieldStr[w.field] = buf;
                break;
            }
        }
        ImGui::PopID();
    }
}

// ---- tab loader (NSJSONSerialization) + hot reload ----------------------
// app-support overrides ship-dropped defaults by id; ASCII filename = order.
static std::string tabsAppSupportDir() {
    NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/NightCityConsole/tabs"];
    return std::string([dir UTF8String]);
}
static std::string tabsShipDir() { return overlayDir() + "/tabs"; }

static WKind wkindFromString(const std::string& s) {
    if (s == "button")     return WK_BUTTON;
    if (s == "checkbox")   return WK_CHECKBOX;
    if (s == "slider_int") return WK_SLIDER_INT;
    if (s == "input_text") return WK_INPUT_TEXT;
    if (s == "separator")  return WK_SEPARATOR;
    if (s == "same_line")  return WK_SAME_LINE;
    return WK_TEXT;
}
static std::string nsStr(NSDictionary* d, const char* key) {
    id v = d[[NSString stringWithUTF8String:key]];
    return [v isKindOfClass:[NSString class]] ? std::string([(NSString*)v UTF8String]) : std::string();
}
static int nsInt(NSDictionary* d, const char* key, int dflt) {
    id v = d[[NSString stringWithUTF8String:key]];
    return [v isKindOfClass:[NSNumber class]] ? [(NSNumber*)v intValue] : dflt;
}

// Parse one tabs/*.json file into a Tab (data tab only). Returns false on error.
static bool parseTabFile(const std::string& path, const std::string& stem, Tab& out) {
    NSString* p = [NSString stringWithUTF8String:path.c_str()];
    NSData* data = [NSData dataWithContentsOfFile:p];
    if (!data) return false;
    NSError* err = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!root || ![root isKindOfClass:[NSDictionary class]]) {
        olog("tab parse failed: %s (%s)", path.c_str(), err ? [[err localizedDescription] UTF8String] : "not an object");
        return false;
    }
    NSDictionary* obj = (NSDictionary*)root;
    out = Tab{};
    out.id = nsStr(obj, "id"); if (out.id.empty()) out.id = stem;
    out.title = nsStr(obj, "title"); if (out.title.empty()) out.title = out.id;
    out.builtin = false;
    out.sourcePath = path;
    id widgets = obj[@"widgets"];
    if ([widgets isKindOfClass:[NSArray class]]) {
        for (id wi in (NSArray*)widgets) {
            if (![wi isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary* wd = (NSDictionary*)wi;
            Widget w;
            w.kind  = wkindFromString(nsStr(wd, "type"));
            w.label = nsStr(wd, "label");
            w.cmd   = nsStr(wd, "cmd");
            w.field = nsStr(wd, "field");
            w.cmdOn = nsStr(wd, "cmd_on");
            w.cmdOff= nsStr(wd, "cmd_off");
            w.toast = nsStr(wd, "toast");
            w.imin  = nsInt(wd, "min", 0);
            w.imax  = nsInt(wd, "max", 100);
            w.idef  = nsInt(wd, "default", 0);
            w.sdef  = nsStr(wd, "default");
            out.widgets.push_back(w);
        }
    }
    return true;
}

// Scan a dir for *.json, return (stem -> path), ASCII-sorted by filename.
static std::vector<std::pair<std::string,std::string>> scanTabDir(const std::string& dir) {
    std::vector<std::pair<std::string,std::string>> out;
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* d = [NSString stringWithUTF8String:dir.c_str()];
    NSArray* files = [fm contentsOfDirectoryAtPath:d error:nil];
    if (!files) return out;
    NSArray* sorted = [files sortedArrayUsingSelector:@selector(compare:)];   // ASCII order
    for (NSString* f in sorted) {
        if (![[f pathExtension] isEqualToString:@"json"]) continue;
        std::string stem = std::string([[f stringByDeletingPathExtension] UTF8String]);
        std::string full = std::string([[d stringByAppendingPathComponent:f] UTF8String]);
        out.push_back({stem, full});
    }
    return out;
}

// Load all data tabs from ship dir + app-support dir (app-support overrides by id).
// Returns them in filename(ASCII) order, app-support entries replacing same-id ship entries in place.
static std::vector<Tab> loadTabsFromDir() {
    std::vector<Tab> result;
    auto ship = scanTabDir(tabsShipDir());
    auto user = scanTabDir(tabsAppSupportDir());
    // index user files by stem for override-by-id
    std::unordered_map<std::string,std::string> userByStem;
    for (auto& u : user) userByStem[u.first] = u.second;
    std::set<std::string> consumedUser;
    for (auto& s : ship) {
        Tab t;
        std::string path = s.second;
        std::string stem = s.first;
        auto uit = userByStem.find(stem);
        if (uit != userByStem.end()) { path = uit->second; consumedUser.insert(stem); }   // override
        if (parseTabFile(path, stem, t)) result.push_back(t);
    }
    // user-only tabs (no ship counterpart) appended in their ASCII order
    for (auto& u : user) {
        if (consumedUser.count(u.first)) continue;
        Tab t;
        if (parseTabFile(u.second, u.first, t)) result.push_back(t);
    }
    return result;
}

// Newest mtime across both tab dirs (and the dirs themselves, to catch add/remove).
static time_t newestTabsMtime() {
    time_t newest = 0;
    NSFileManager* fm = [NSFileManager defaultManager];
    const std::string dirs[2] = { tabsShipDir(), tabsAppSupportDir() };
    for (const std::string& dir : dirs) {
        NSString* d = [NSString stringWithUTF8String:dir.c_str()];
        NSDictionary* dattr = [fm attributesOfItemAtPath:d error:nil];
        if (dattr) { NSDate* m = dattr[NSFileModificationDate]; if (m) { time_t t = (time_t)[m timeIntervalSince1970]; if (t > newest) newest = t; } }
        NSArray* files = [fm contentsOfDirectoryAtPath:d error:nil];
        for (NSString* f in files) {
            if (![[f pathExtension] isEqualToString:@"json"]) continue;
            NSString* full = [d stringByAppendingPathComponent:f];
            NSDictionary* attr = [fm attributesOfItemAtPath:full error:nil];
            if (!attr) continue;
            NSDate* m = attr[NSFileModificationDate];
            if (m) { time_t t = (time_t)[m timeIntervalSince1970]; if (t > newest) newest = t; }
        }
    }
    return newest;
}

// Rebuild g_tabs: the four builtins first (in fixed order), then every data tab.
static void rebuildTabs() {
    std::vector<Tab> dataTabs = loadTabsFromDir();
    std::lock_guard<std::mutex> lk(g_tabsMtx);
    g_tabs.clear();
    Tab console; console.id = "console"; console.title = "Console"; console.builtin = true; console.nativeKind = "console";
    Tab items;   items.id   = "items";   items.title   = "Items";   items.builtin = true; items.nativeKind = "items";   items.nativeDraw = drawItemsTab;
    Tab quick;   quick.id   = "quick";   quick.title   = "Quick";   quick.builtin = true; quick.nativeKind = "quick";   quick.nativeDraw = drawQuickTab;
    Tab creator; creator.id = "creator"; creator.title = "Creator"; creator.builtin = true; creator.nativeKind = "creator"; creator.nativeDraw = drawCreatorTab;
    Tab mods;    mods.id    = "mods";    mods.title    = "Mods";    mods.builtin    = true; mods.nativeKind    = "mods";    mods.nativeDraw    = drawModsTab;
    g_tabs.push_back(console);
    g_tabs.push_back(items);
    g_tabs.push_back(quick);
    g_tabs.push_back(creator);
    g_tabs.push_back(mods);
    for (auto& dt : dataTabs) g_tabs.push_back(dt);
    g_numTabs = (int)g_tabs.size();
    olog("tabs rebuilt: %d total (%zu data)", g_numTabs, dataTabs.size());
}

// Console tab body, factored out so the tab loop can call it for the builtin Console tab.
static void drawConsoleInner(int req, int myTab) {
    ImGui::BeginChild("scroll", ImVec2(0, -ImGui::GetFrameHeightWithSpacing()), false, ImGuiWindowFlags_HorizontalScrollbar);
    for (auto& l : g_lines) ImGui::TextUnformatted(l.c_str());
    if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 4.0f) ImGui::SetScrollHereY(1.0f);
    ImGui::EndChild();
    ImGui::Separator();
    ImGui::SetNextItemWidth(-1.0f);
    if (g_focusInput.exchange(false)) ImGui::SetKeyboardFocusHere();
    ImGuiInputTextFlags flags = ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_CallbackHistory;
    if (ImGui::InputText("##cmd", g_input, sizeof(g_input), flags, inputCallback)) {
        if (g_input[0]) {
            if (g_history.empty() || g_history.back() != g_input) g_history.push_back(g_input);
            g_historyPos = -1;
            handleSubmit(g_input);
            g_input[0] = 0;
        }
        ImGui::SetKeyboardFocusHere(-1);
    }
}

static void drawConsole() {
    if (g_tabsDirty.exchange(false)) rebuildTabs();
    ImGui::SetNextWindowSize(ImVec2(860, 480), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(48, 48), ImGuiCond_FirstUseEver);
    ImGui::Begin("NightCity Console  ( ` or F1 to toggle )");
    ImGui::TextDisabled("Cmd+1..9 switch tabs   (`reload` re-reads tabs/)");
    int req = -1;
    if (g_tabReq.exchange(false)) req = g_activeTab.load();   // a keyboard tab-switch this frame
    std::lock_guard<std::mutex> lk(g_tabsMtx);
    if (ImGui::BeginTabBar("cetmac_tabs")) {
        for (int i = 0; i < (int)g_tabs.size(); ++i) {
            const Tab& t = g_tabs[i];
            ImGuiTabItemFlags tf = (req == i) ? ImGuiTabItemFlags_SetSelected : 0;
            if (ImGui::BeginTabItem(t.title.c_str(), nullptr, tf)) {
                if (t.builtin && t.nativeKind == "console") drawConsoleInner(req, i);
                else if (t.builtin && t.nativeDraw)         t.nativeDraw();
                else                                        drawDataTab(t);
                ImGui::EndTabItem();
            }
        }
        ImGui::EndTabBar();
    }
    if (!g_lastAction.empty()) {
        ImGui::Separator();
        ImGui::TextColored(ImVec4(0.45f, 1.0f, 0.55f, 1.0f), "%s", g_lastAction.c_str());
    }
    ImGui::End();
}

static void renderOverlay(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable) {
    static std::atomic<bool> firstLogged{false};
    if (!firstLogged.exchange(true))
        olog("present FIRED: cb=%s drawable=%p tex=%p", cb ? class_getName(object_getClass(cb)) : "null",
             (__bridge void*)drawable, (__bridge void*)(drawable ? drawable.texture : nil));   // one-time diagnostic
    if (!cb || !drawable) return;
    // When the console is hidden there is nothing to draw. Skip the entire render pass:
    // encoding an empty ImGui frame plus a Load-action render command encoder every frame
    // costs real GPU time (a full-framebuffer memory round-trip) and stutters in dense,
    // GPU-bound interiors. Bail before we touch the GPU so a closed console is free.
    if (!g_show.load()) return;
    id<MTLTexture> tex = drawable.texture; if (!tex) return;
    id<MTLDevice> dev = cb.device;
    if (!g_imguiInit) initImGui(dev);
    g_frame++;
    if ((g_frame % 60) == 0) refreshOut();

    // Hot-reload tabs: poll the newest tabs/ mtime ~once/sec; on change, mark dirty.
    // drawConsole() consumes g_tabsDirty and calls rebuildTabs() under g_tabsMtx.
    {
        static double s_lastPoll = 0.0;
        static time_t s_lastMtime = 0;
        double now = CACurrentMediaTime();
        if (now - s_lastPoll > 1.0) {
            s_lastPoll = now;
            time_t m = newestTabsMtime();
            if (m != s_lastMtime) { s_lastMtime = m; g_tabsDirty = true; }
        }
    }

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = tex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)tex.width, (float)tex.height);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    io.DeltaTime = 1.0f / 60.0f;
    drainEvents();

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    if (g_show.load()) { drawConsole(); luaRunOnDraw(); }   // Q8: Lua mods draw their own windows
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (!enc) return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
}

static void runRender(id self, id drawable) {
    // Perf: nothing is drawn when the console is closed (drawConsole()/luaRunOnDraw() are g_show-gated), yet
    // compositing an empty ImGui pass every frame still re-loads+stores the whole framebuffer (loadAction=Load)
    // and serializes against the game's GPU work - measured ~40-60ms/frame at 4K with the console CLOSED. Skip
    // the whole pass when closed; the present hook stays installed so backtick still opens it instantly.
    if (!g_show.load()) return;
    @autoreleasepool {
        @try { renderOverlay((id<MTLCommandBuffer>)self, (id<CAMetalDrawable>)drawable); }
        @catch (NSException* e) { olog("render exception: %s", [[e reason] UTF8String]); }
    }
}
static IMP origPresentFor(id self, SEL _cmd) {
    Method m = class_getInstanceMethod(object_getClass(self), _cmd);
    auto it = g_origPresents.find((void*)m);
    return it != g_origPresents.end() ? it->second : NULL;
}
// The game may present via presentDrawable:, presentDrawable:atTime:, or presentDrawable:afterMinimumDuration:
// (newer hardware/displays use the frame-paced variants). Render in all three, then chain to the original.
// A present can be nested (e.g. the MTL3On4 compat wrapper forwards to the underlying AGX buffer's present,
// and we hook both); render ONLY at the outermost call so we don't draw the overlay twice per frame.
static thread_local int g_presentDepth = 0;
static void my_presentDrawable(id self, SEL _cmd, id drawable) {
    if (g_presentDepth == 0 && g_mode == NCC_FULL) runRender(self, drawable);
    g_presentDepth++;
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id))o)(self, _cmd, drawable);
    g_presentDepth--;
}
static void my_presentAtTime(id self, SEL _cmd, id drawable, CFTimeInterval t) {
    if (g_presentDepth == 0 && g_mode == NCC_FULL) runRender(self, drawable);
    g_presentDepth++;
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id, CFTimeInterval))o)(self, _cmd, drawable, t);
    g_presentDepth--;
}
static void my_presentAfter(id self, SEL _cmd, id drawable, CFTimeInterval d) {
    if (g_presentDepth == 0 && g_mode == NCC_FULL) runRender(self, drawable);
    g_presentDepth++;
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id, CFTimeInterval))o)(self, _cmd, drawable, d);
    g_presentDepth--;
}

static void my_sendEvent(id self, SEL _cmd, NSEvent* ev) {
    @try {
        NSEventType t = ev.type;
        if (t == NSEventTypeKeyDown) {
            unsigned short kc = ev.keyCode;
            if (kc == 50 || kc == 122) {  // ` (grave/tilde) or F1
                bool now = !g_show.load();
                g_show = now;
                if (now) { g_focusInput = true; g_recenterMouse = true; NSWindow* w = ev.window; if (w) [w setAcceptsMouseMovedEvents:YES]; }
                return;  // swallow the toggle key
            }
            // Cmd+1 .. Cmd+9 switch tabs (the game captures the mouse, so tabs are keyboard-driven).
            // mac virtual keycodes for the digit-row 1..9 (not contiguous: 5/6 and 7/8 are swapped).
            if (g_show.load() && (ev.modifierFlags & NSEventModifierFlagCommand)) {
                static const unsigned short kNum[9] = {18, 19, 20, 21, 23, 22, 26, 28, 25};
                int tab = -1;
                for (int d = 0; d < 9; ++d) if (kc == kNum[d]) { tab = d; break; }
                if (tab >= 0 && tab < g_numTabs) {
                    g_activeTab = tab; g_tabReq = true;
                    if (tab == 0) g_focusInput = true;        // Console tab -> focus the input line
                    if (tab == 1) g_itemsTabEntered = true;   // Items tab -> focus its search box
                    return;  // swallow
                }
                if (tab >= 0) return;  // a digit we recognize but no such tab: still swallow
                if (kc == 35) { g_pinTopReq = true; return; }   // Cmd+P pins the current top search result
                if (kc == 5)  { g_catFilter = (g_catFilter.load() + 1) % g_numCategories; g_catReq = true; return; }  // Cmd+G cycles item category
            }
        }
        if (g_show.load()) {
            pushEventFromNS(ev);
            if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp || t == NSEventTypeFlagsChanged ||
                t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown ||
                t == NSEventTypeRightMouseUp || t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged ||
                t == NSEventTypeRightMouseDragged || t == NSEventTypeScrollWheel)
                return;  // swallow so the game doesn't react while the console is open
        }
    } @catch (NSException* e) { olog("sendEvent exception: %s", [[e reason] UTF8String]); }
    ((void(*)(id, SEL, id))g_origSendEvent)(self, _cmd, ev);
}

// Diagnostic: hook CAMetalLayer.nextDrawable (called every frame by any Metal app, regardless of how it
// presents) to capture the live drawable class - so if presentDrawable* never fires we still learn the path.
static IMP g_origNextDrawable = NULL;
static id my_nextDrawable(id self, SEL _cmd) {
    id d = ((id(*)(id, SEL))g_origNextDrawable)(self, _cmd);
    frameTick();   // once per frame, every mode: our frame-cadence probe
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true))
        olog("nextDrawable FIRED: layer=%s drawable=%s", class_getName(object_getClass(self)),
             d ? class_getName(object_getClass(d)) : "null");
    return d;
}
static void installLayerDiag() {
    Class c = objc_getClass("CAMetalLayer");
    if (!c) { olog("diag: no CAMetalLayer"); return; }
    Method m = class_getInstanceMethod(c, sel_registerName("nextDrawable"));
    if (!m) { olog("diag: no nextDrawable on CAMetalLayer"); return; }
    g_origNextDrawable = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_nextDrawable);
    olog("hooked nextDrawable on CAMetalLayer (diag)");
}

static void installPresentHook() {
    if (g_mode == NCC_OFF) { olog("NCC_MODE=off: present hook NOT installed (bisection)"); return; }
    // Force the GPU-family command-buffer class (AGXG16F etc.) to load so the scan below sees it.
    @try {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) { id<MTLCommandQueue> q = [dev newCommandQueue]; if (q) [q commandBuffer]; }
    } @catch (NSException*) {}
    struct Variant { const char* sel; IMP imp; };
    Variant variants[] = {
        { "presentDrawable:", (IMP)my_presentDrawable },
        { "presentDrawable:atTime:", (IMP)my_presentAtTime },
        { "presentDrawable:afterMinimumDuration:", (IMP)my_presentAfter },
    };
    int n = objc_getClassList(NULL, 0);
    Class* list = (Class*)malloc(sizeof(Class) * n);
    objc_getClassList(list, n);
    int hooked = 0;
    // Swizzle every command-buffer class's present methods (all three variants; dedupe inherited methods by
    // Method pointer). Catches whichever class AND present variant the game uses, on any chip/display.
    for (int i = 0; i < n; i++) {
        const char* nm = class_getName(list[i]);
        if (!nm || !strstr(nm, "CommandBuffer")) continue;
        for (auto& v : variants) {
            Method m = class_getInstanceMethod(list[i], sel_registerName(v.sel));
            if (!m) continue;
            if (g_origPresents.count((void*)m)) continue;   // already hooked (shared/inherited method)
            g_origPresents[(void*)m] = method_getImplementation(m);
            method_setImplementation(m, v.imp);
            hooked++;
            olog("hooked %s on %s", v.sel, nm);
        }
    }
    free(list);
    if (!hooked) olog("FATAL: no command-buffer present method found");
}

static void installInputHook() {
    id app = ((id(*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    if (!app) { olog("FATAL: no NSApplication"); return; }
    Class appClass = object_getClass(app);
    SEL sel = sel_registerName("sendEvent:");
    Method m = class_getInstanceMethod(appClass, sel);
    if (!m) { olog("FATAL: no sendEvent: on %s", class_getName(appClass)); return; }
    g_origSendEvent = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_sendEvent);
    olog("hooked sendEvent: on %s", class_getName(appClass));
}

__attribute__((constructor))
static void overlay_init() {
    readMode();
    olog("==== CP2077 overlay dylib loaded (NCC_MODE=%s) ====", modeName());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installPresentHook();
        installInputHook();
        installLayerDiag();
    });
}
