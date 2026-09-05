/**
 * RED4ext Hooks for macOS - Frida Gadget Implementation
 * 
 * This script implements the RED4ext hook system using Frida's Interceptor API,
 * bypassing Apple Silicon's W^X enforcement through JIT-based trampolines.
 * 
 * @version 1.1.0
 * @author RED4ext macOS Port
 */

'use strict';

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
    // Log level: 0=errors only, 1=info, 2=debug, 3=trace
    logLevel: 1,
    
    // Log prefix for all messages
    logPrefix: '[RED4ext-Frida]',
    
    // Module name to hook (main game executable)
    targetModule: 'Cyberpunk2077',
    
    // Hook offsets from __TEXT segment base
    hooks: {
        // Main function - App startup/shutdown
        0x0E54032B: { name: 'Main', offset: 0x31E18, enabled: true },
        
        // CGameApplication::AddState - Game state management
        0xFBC216B3: { name: 'CGameApplication_AddState', offset: 0x3F22E98, enabled: true },
        
        // Global::ExecuteProcess - Script compilation redirect
        0x835D1F2F: { name: 'Global_ExecuteProcess', offset: 0x1D46808, enabled: true },
        
        // CBaseEngine::InitScripts - Script initialization
        0xAB652585: { name: 'CBaseEngine_InitScripts', offset: 0x3D8C1A0, enabled: true },
        
        // CBaseEngine::LoadScripts - Script loading
        0xD4CB1D59: { name: 'CBaseEngine_LoadScripts', offset: 0x3D9A03C, enabled: true },
        
        // ScriptValidator::Validate - Script validation
        0x359024C2: { name: 'ScriptValidator_Validate', offset: 0x3D96BFC, enabled: true },
        
        // AssertionFailed - Assertion logging
        0xFF6B0CB1: { name: 'AssertionFailed', offset: 0x3C3D4C, enabled: true },
        
        // GameInstance::CollectSaveableSystems - Save system
        0xC0886390: { name: 'GameInstance_CollectSaveableSystems', offset: 0x87FEC, enabled: true },
        
        // GsmState_SessionActive::ReportErrorCode - Session state
        0x7FA31576: { name: 'GsmState_SessionActive_ReportErrorCode', offset: 0x3F5E9B0, enabled: true },
        
        // =====================================================================
        // TweakXL-specific hooks (TweakDB functions)
        // NOTE: Offsets need to be found via reverse engineering
        // =====================================================================
        
        // TweakDB_Init - Database initialization (hash: 3062572522)
        0xB6832FEA: { name: 'TweakDB_Init', offset: 0x0, enabled: false },
        
        // TweakDB_Load - Load optimized DB (hash: 3602585178)
        0xD6B1DB5A: { name: 'TweakDB_Load', offset: 0x0, enabled: false },
        
        // TweakDB_TryLoad - Try loading DB (hash: 3512345737)
        0xD16A2999: { name: 'TweakDB_TryLoad', offset: 0x0, enabled: false },
        
        // TweakDB_CreateRecord - Create DB record (hash: 838931066)
        0x31FB0F6A: { name: 'TweakDB_CreateRecord', offset: 0x0, enabled: false },
        
        // TweakDBID_Derive - Derive TweakDB ID (hash: 326438016)
        0x137620C0: { name: 'TweakDBID_Derive', offset: 0x0, enabled: false },
    }
};

// ============================================================================
// Logging
// ============================================================================

const LogLevel = {
    ERROR: 0,
    INFO: 1,
    DEBUG: 2,
    TRACE: 3
};

function log(level, message) {
    if (level <= CONFIG.logLevel) {
        const prefix = level === LogLevel.ERROR ? '[ERROR]' : 
                       level === LogLevel.DEBUG ? '[DEBUG]' : 
                       level === LogLevel.TRACE ? '[TRACE]' : '';
        console.log(`${CONFIG.logPrefix} ${prefix} ${message}`.trim());
    }
}

function logError(msg) { log(LogLevel.ERROR, msg); }
function logInfo(msg) { log(LogLevel.INFO, msg); }
function logDebug(msg) { log(LogLevel.DEBUG, msg); }
function logTrace(msg) { log(LogLevel.TRACE, msg); }

// ============================================================================
// Safe Memory Access Utilities
// ============================================================================

function safeReadPointer(ptr) {
    try {
        if (ptr.isNull()) return null;
        // Check if pointer looks valid (in reasonable address range)
        const addr = ptr.toUInt32 ? ptr.toUInt32() : parseInt(ptr.toString());
        if (addr < 0x1000 || addr > 0x7FFFFFFFFFFF) return null;
        return ptr.readPointer();
    } catch (e) {
        return null;
    }
}

function safeReadCString(ptr, maxLen = 256) {
    try {
        if (ptr.isNull()) return null;
        const addr = ptr.toUInt32 ? ptr.toUInt32() : parseInt(ptr.toString());
        if (addr < 0x1000 || addr > 0x7FFFFFFFFFFF) return null;
        return ptr.readCString(maxLen);
    } catch (e) {
        return null;
    }
}

function safeReadInt32(ptr) {
    try {
        if (ptr.isNull()) return null;
        return ptr.toInt32();
    } catch (e) {
        return null;
    }
}

function formatPtr(ptr) {
    if (!ptr) return 'null';
    try {
        return ptr.toString();
    } catch (e) {
        return 'invalid';
    }
}

// ============================================================================
// Module Resolution
// ============================================================================

let moduleBase = null;
let hookCount = 0;
let hookStats = {};

function getModuleBase() {
    if (moduleBase !== null) {
        return moduleBase;
    }
    
    const modules = Process.enumerateModules();
    
    for (const mod of modules) {
        if (mod.name.includes(CONFIG.targetModule)) {
            moduleBase = mod.base;
            logInfo(`Found module '${mod.name}' at base ${mod.base}`);
            return moduleBase;
        }
    }
    
    // Fallback: use the first module (main executable)
    if (modules.length > 0) {
        moduleBase = modules[0].base;
        logInfo(`Using fallback module '${modules[0].name}' at base ${modules[0].base}`);
        return moduleBase;
    }
    
    logError('Could not find target module!');
    return null;
}

// ============================================================================
// Hook Handlers
// ============================================================================

/**
 * Hook: Main
 */
function hookMain(address) {
    let gameStartTime = null;
    
    Interceptor.attach(address, {
        onEnter: function(args) {
            gameStartTime = Date.now();
            logInfo('Main() called - Game starting');
            hookStats['Main'] = (hookStats['Main'] || 0) + 1;
        },
        onLeave: function(retval) {
            const elapsed = gameStartTime ? (Date.now() - gameStartTime) : 0;
            logInfo(`Main() returned after ${elapsed}ms - Game shutting down`);
        }
    });
}

/**
 * Hook: CGameApplication::AddState
 */
function hookCGameApplication_AddState(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['AddState'] = (hookStats['AddState'] || 0) + 1;
            logInfo('CGameApplication::AddState called');
            logTrace(`  this: ${formatPtr(args[0])}, state: ${formatPtr(args[1])}`);
        },
        onLeave: function(retval) {
            logTrace(`CGameApplication::AddState returned: ${retval}`);
        }
    });
}

/**
 * Hook: Global::ExecuteProcess
 */
function hookGlobal_ExecuteProcess(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['ExecuteProcess'] = (hookStats['ExecuteProcess'] || 0) + 1;
            
            // Try to read command string safely
            const commandPtr = args[1];
            let commandStr = null;
            
            if (commandPtr && !commandPtr.isNull()) {
                // CString typically has char* at offset 0 or has inline storage
                const innerPtr = safeReadPointer(commandPtr);
                if (innerPtr) {
                    commandStr = safeReadCString(innerPtr);
                }
            }
            
            if (commandStr) {
                logInfo(`ExecuteProcess: ${commandStr}`);
                if (commandStr.includes('scc')) {
                    logInfo('  -> Script compiler detected');
                    this.isScc = true;
                }
            } else {
                logDebug('ExecuteProcess called (could not read command)');
            }
        },
        onLeave: function(retval) {
            if (this.isScc) {
                const success = retval.toInt32();
                logInfo(`Script compilation ${success ? 'succeeded' : 'failed'}`);
            }
        }
    });
}

/**
 * Hook: CBaseEngine::InitScripts
 */
function hookCBaseEngine_InitScripts(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['InitScripts'] = (hookStats['InitScripts'] || 0) + 1;
            logInfo('CBaseEngine::InitScripts called');
        },
        onLeave: function(retval) {
            logInfo('CBaseEngine::InitScripts completed');
        }
    });
}

/**
 * Hook: CBaseEngine::LoadScripts
 */
function hookCBaseEngine_LoadScripts(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['LoadScripts'] = (hookStats['LoadScripts'] || 0) + 1;
            logInfo('CBaseEngine::LoadScripts called');
        },
        onLeave: function(retval) {
            logInfo('CBaseEngine::LoadScripts completed');
        }
    });
}

/**
 * Hook: ScriptValidator::Validate
 */
function hookScriptValidator_Validate(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['Validate'] = (hookStats['Validate'] || 0) + 1;
            logDebug('ScriptValidator::Validate called');
        },
        onLeave: function(retval) {
            const result = safeReadInt32(retval);
            if (result !== null && result !== 0) {
                logInfo(`ScriptValidator::Validate found issues (code: ${result})`);
            }
        }
    });
}

/**
 * Hook: AssertionFailed
 */
function hookAssertionFailed(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['AssertionFailed'] = (hookStats['AssertionFailed'] || 0) + 1;
            
            logError('=== ASSERTION FAILED ===');
            
            const file = safeReadCString(args[0]);
            const line = safeReadInt32(args[1]);
            const expr = safeReadCString(args[2]);
            const msg = safeReadCString(args[3]);
            
            if (file) logError(`  File: ${file}`);
            if (line !== null) logError(`  Line: ${line}`);
            if (expr) logError(`  Expression: ${expr}`);
            if (msg) logError(`  Message: ${msg}`);
            
            logError('========================');
        }
    });
}

/**
 * Hook: GameInstance::CollectSaveableSystems
 */
function hookGameInstance_CollectSaveableSystems(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['CollectSaveableSystems'] = (hookStats['CollectSaveableSystems'] || 0) + 1;
            logDebug('GameInstance::CollectSaveableSystems called');
        }
    });
}

/**
 * Hook: GsmState_SessionActive::ReportErrorCode
 */
function hookGsmState_SessionActive_ReportErrorCode(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['ReportErrorCode'] = (hookStats['ReportErrorCode'] || 0) + 1;
            
            const errorCode = safeReadInt32(args[1]);
            if (errorCode !== null && errorCode !== 0) {
                logInfo(`GsmState_SessionActive::ReportErrorCode - Error: ${errorCode}`);
            }
        }
    });
}

// ============================================================================
// TweakXL Hook Handlers
// ============================================================================

/**
 * Hook: TweakDB_Init - Database initialization
 */
function hookTweakDB_Init(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_Init'] = (hookStats['TweakDB_Init'] || 0) + 1;
            logInfo('TweakDB::Init called - TweakDB initializing');
            logTrace(`  this: ${formatPtr(args[0])}, arg1: ${formatPtr(args[1])}`);
        },
        onLeave: function(retval) {
            logInfo('TweakDB::Init completed');
        }
    });
}

/**
 * Hook: TweakDB_Load - Load optimized database
 */
function hookTweakDB_Load(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_Load'] = (hookStats['TweakDB_Load'] || 0) + 1;
            logInfo('TweakDB::Load called - Loading TweakDB');
            
            // Try to read the path argument (CString)
            const pathPtr = args[1];
            if (pathPtr && !pathPtr.isNull()) {
                const innerPtr = safeReadPointer(pathPtr);
                if (innerPtr) {
                    const path = safeReadCString(innerPtr);
                    if (path) {
                        logInfo(`  Loading: ${path}`);
                    }
                }
            }
        },
        onLeave: function(retval) {
            logInfo('TweakDB::Load completed');
        }
    });
}

/**
 * Hook: TweakDB_TryLoad - Try loading database
 */
function hookTweakDB_TryLoad(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_TryLoad'] = (hookStats['TweakDB_TryLoad'] || 0) + 1;
            logInfo('TweakDB::TryLoad called');
        },
        onLeave: function(retval) {
            const success = retval.toInt32();
            logInfo(`TweakDB::TryLoad ${success ? 'succeeded' : 'failed'}`);
        }
    });
}

/**
 * Hook: TweakDB_CreateRecord - Create database record
 */
function hookTweakDB_CreateRecord(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_CreateRecord'] = (hookStats['TweakDB_CreateRecord'] || 0) + 1;
            logDebug('TweakDB::CreateRecord called');
            
            // args[0] = this (TweakDB*)
            // args[1] = recordType (uint32)
            // args[2] = recordId (TweakDBID)
            const recordType = safeReadInt32(args[1]);
            if (recordType !== null) {
                logTrace(`  recordType: 0x${recordType.toString(16)}`);
            }
        }
    });
}

/**
 * Hook: TweakDBID_Derive - Derive TweakDB ID from base
 */
function hookTweakDBID_Derive(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDBID_Derive'] = (hookStats['TweakDBID_Derive'] || 0) + 1;
            
            // args[2] = name string
            const nameStr = safeReadCString(args[2]);
            if (nameStr) {
                logTrace(`TweakDBID::Derive: ${nameStr}`);
            }
        }
    });
}

// ============================================================================
// Hook Installation
// ============================================================================

const hookFunctions = {
    'Main': hookMain,
    'CGameApplication_AddState': hookCGameApplication_AddState,
    'Global_ExecuteProcess': hookGlobal_ExecuteProcess,
    'CBaseEngine_InitScripts': hookCBaseEngine_InitScripts,
    'CBaseEngine_LoadScripts': hookCBaseEngine_LoadScripts,
    'ScriptValidator_Validate': hookScriptValidator_Validate,
    'AssertionFailed': hookAssertionFailed,
    'GameInstance_CollectSaveableSystems': hookGameInstance_CollectSaveableSystems,
    'GsmState_SessionActive_ReportErrorCode': hookGsmState_SessionActive_ReportErrorCode,
    // TweakXL hooks
    'TweakDB_Init': hookTweakDB_Init,
    'TweakDB_Load': hookTweakDB_Load,
    'TweakDB_TryLoad': hookTweakDB_TryLoad,
    'TweakDB_CreateRecord': hookTweakDB_CreateRecord,
    'TweakDBID_Derive': hookTweakDBID_Derive,
};

function installHooks() {
    console.log(`${CONFIG.logPrefix} ========================================`);
    console.log(`${CONFIG.logPrefix} RED4ext Frida Hooks - Initializing`);
    console.log(`${CONFIG.logPrefix} ========================================`);
    
    const base = getModuleBase();
    if (base === null) {
        logError('Failed to get module base address');
        return;
    }
    
    logInfo(`Module base: ${base}`);
    logInfo('');
    logInfo('Installing hooks...');
    
    for (const [hashStr, hookInfo] of Object.entries(CONFIG.hooks)) {
        const { name, offset, enabled } = hookInfo;
        
        if (!enabled) {
            logDebug(`  [SKIP] ${name} (disabled)`);
            continue;
        }
        
        const hookFunc = hookFunctions[name];
        if (!hookFunc) {
            logError(`  [ERROR] ${name} - No handler function`);
            continue;
        }
        
        try {
            const address = base.add(offset);
            hookFunc(address);
            hookCount++;
            logInfo(`  [OK] ${name} at ${address} (offset 0x${offset.toString(16)})`);
        } catch (e) {
            logError(`  [FAIL] ${name} - ${e.message}`);
        }
    }
    
    logInfo('');
    console.log(`${CONFIG.logPrefix} Hook installation complete: ${hookCount}/${Object.keys(CONFIG.hooks).length} hooks active`);
    console.log(`${CONFIG.logPrefix} ========================================`);
}

// ============================================================================
// Entry Point
// ============================================================================

installHooks();

// Export for external access
rpc.exports = {
    getHookCount: function() {
        return hookCount;
    },
    
    getHookStats: function() {
        return JSON.stringify(hookStats);
    },
    
    setLogLevel: function(level) {
        CONFIG.logLevel = level;
        return `Log level set to ${level}`;
    }
};

// ============================================================================
// CP2077SaveKit MINI-CET v3 -- universal RTTI call + enums + chains.
//   give <Items.NAME> <qty> | money <amt> | call <Class> <method> [args] | perks <n> | attrs <n> | relic <n>
//   resetperks | resetattrs
// Resolves ANY method via CClass.funcs (+0x48), walks parents; live instance per class; enum args by name.
// ============================================================================
(function () {
    const OUT='/tmp/cp2077_out.txt', CMD='/tmp/cp2077_cmd.txt';
    const LREQ='/tmp/cp2077_lreq.txt', LRES='/tmp/cp2077_lres.txt';   // Q7 Lua Game.* call bridge (request/response)
    function log(s){ try{const f=new File(OUT,'a');f.write(s+'\n');f.flush();f.close();}catch(e){} try{console.log('[MINICET] '+s);}catch(e2){} }
    function readFile(p){ try{return File.readAllText(p);}catch(e){return null;} }
    function clearFile(p){ try{const f=new File(p,'w');f.write('');f.close();}catch(e){} }
    function fnv(str){ let h=BigInt('0xCBF29CE484222325'); const P=BigInt('0x100000001b3'),M=(BigInt(1)<<BigInt(64))-BigInt(1); for(let i=0;i<str.length;i++){h^=BigInt(str.charCodeAt(i));h=(h*P)&M;} return h; }
    function u64(bi){ return uint64('0x'+bi.toString(16)); }
    function crc32(str){ let crc=0xFFFFFFFF; for(let i=0;i<str.length;i++){ let c=(crc^str.charCodeAt(i))&0xFF; for(let k=0;k<8;k++) c=(c&1)?(0xEDB88320^(c>>>1)):(c>>>1); crc=(crc>>>8)^c; } return (crc^0xFFFFFFFF)>>>0; }
    function tdbidBytes(n){ const h=crc32(n); return [h&0xff,(h>>>8)&0xff,(h>>>16)&0xff,(h>>>24)&0xff,n.length&0xff,0,0,0]; }
    const FV0=ptr('0x100000000');
    const T_I32='0xb9a127f5b4a621bf',T_U32='0x3d2e9dd9e3c28d8c',T_I64='0xb9902ff5b497bc24',T_U64='0x3d3f99d9e3d0f9f3',
          T_F32='0xb64f4a0accc8a8c5',T_BOOL='0xf7bdd5a7c820889d',T_CNAME='0xa5e23de2a2657af9',T_TDB='0x4072151ff3dcf7bc',T_ITEM='0xd15b2274885d7f7d';
    const PLAYER='0xcebecae898e55b86';
    try {
        const base=getModuleBase(); const execAddr=base.add(0x2173120);
        const Exec=new NativeFunction(execAddr,'uint64',['pointer','pointer','pointer','pointer','pointer']);
        let reg=null,GetClass=null,GetEnum=null;
        function ensureReg(){ if(reg) return; reg=new NativeFunction(base.add(0x2188e8c),'pointer',[])(); const rv=reg.readPointer();
            GetClass=new NativeFunction(rv.add(0x10).readPointer(),'pointer',['pointer','uint64']);
            GetEnum =new NativeFunction(rv.add(0x18).readPointer(),'pointer',['pointer','uint64']); }
        let player=null, playerVt=null, fromtd=null, depth=0, busy=false, lastCmd='', lastLReq=''; const pendingQ=[];
        const playerCands=[], playerCandSet=new Set(); let devOwner=null;  // cached dev-data owner (the local player)
        function addCand(ctx){ const k=ctx.toString(); if(playerCandSet.has(k)) return; playerCandSet.add(k); playerCands.push(ctx); if(playerCands.length>8){ const old=playerCands.shift(); playerCandSet.delete(old.toString()); } }
        const instReg={}, seenVt=new Set(); let nameHookInstalled=false;
        const refcnt=Memory.alloc(8); refcnt.writeU32(0x100000); refcnt.add(4).writeU32(0x100000);
        function nameOf(metaObj){ try{ const gn=metaObj.readPointer().add(0x10).readPointer(); return '0x'+new NativeFunction(gn,'uint64',['pointer'])(metaObj).toString(16);}catch(e){return null;} }
        function hexp(pp,nn){ try{const b=new Uint8Array(pp.readByteArray(nn));let r='';for(let i=0;i<b.length;i++)r+=('0'+b[i].toString(16)).slice(-2)+' ';return r.trim();}catch(e){return 'ERR';} }
        function sigStr(fn){ try{ const pe=fn.add(0x28).readPointer(), pc=fn.add(0x30).readU32(); let p=[]; for(let i=0;i<pc;i++){ p.push(nameOf(pe.add(i*8).readPointer().readPointer())); } return 'params['+pc+']=['+p.join(',')+']'; }catch(e){ return 'sigErr'; } }
        function clsByName(n){ ensureReg(); const m=GetClass(reg,u64(fnv(n))); return m.isNull()?null:m; }
        // universal: find a method (CClassFunction*) by class name + short name, walking parents
        function resolveFunc(className, method){ let cls=clsByName(className); const mh=fnv(method);
            while(cls && !cls.isNull()){
                for(const off of [0x48, 0x58]){            // instance funcs, then STATIC funcs
                    const fp=cls.add(off).readPointer(); const n=cls.add(off+8).readU32();
                    if(!fp.isNull()){ for(let i=0;i<n;i++){ const f=fp.add(i*8).readPointer(); if(f.isNull())continue;
                        if(f.add(0x10).readU64().equals(u64(mh))){ const rp=f.add(0x18).readPointer(); return {fn:f, retType:rp.isNull()?ptr(0):rp.readPointer(), isStatic:(off===0x58)}; } } }
                }
                cls=cls.add(0x10).readPointer(); }            // parent
            return null; }
        // ===== Observe(class, method, cb): fire JS when the game runs a scripted/native function. =====
        // Built on the existing global-Executor hook below. methodHash=fnv(shortName) matches fn+0x10
        // (the same key resolveFunc uses); classHash=fnv(className) is matched against the instance's
        // class chain (walks parents, so subclasses match too). cb(ctx, frame, fn) runs BEFORE the
        // original. With no cb it's a throttled diagnostic that dumps ctx/frame/signature so we can
        // decode real args from reality first (verify-the-reference), then write real callbacks.
        let obsByMethod = {};   // '0x<methodHash>' -> [observer, ...]
        let obsCount = 0;
        function classIsA(meta, wantHash){ let c=meta, g=0; while(c && !c.isNull() && g++<24){ try{ if(nameOf(c)===wantHash) return true; }catch(e){ return false; } c=c.add(0x10).readPointer(); } return false; }
        function obsFire(ob, ctx, frame, fn){
            if(ob.diag && ob.hits<12){ ob.hits++;
                let sig=''; try{ sig=sigStr(fn); }catch(e){ sig='sigErr'; }
                let fr=''; try{ fr=hexp(frame,0x60); }catch(e){ fr='ERR'; }
                log('OBSERVE '+ob.className+'.'+ob.methodName+' #'+ob.hits+' ctx='+ctx+' frame='+frame+' '+sig);
                log('   frame[0x60]='+fr); }
            if(ob.cb){ try{ ob.cb(ctx, frame, fn); }catch(e){ log('observe cb err ('+ob.methodName+'): '+e); } }
        }
        // Register an observer. className=null -> match the method on ANY class. Returns the observer obj.
        function cmObserve(className, methodName, cb, opts){
            const mh='0x'+fnv(methodName).toString(16);
            const ch=className?('0x'+fnv(className).toString(16)):null;
            const ob={ classHash:ch, className:className||'*', methodName:methodName, cb:cb||null, hits:0, diag:(!cb)||!!(opts&&opts.diag) };
            (obsByMethod[mh]=obsByMethod[mh]||[]).push(ob); obsCount++;
            log('observe + '+ob.className+'.'+methodName+'  (methodHash '+mh+(ch?(', classHash '+ch):'')+')');
            return ob;
        }
        function cmUnobserve(){ obsByMethod={}; obsCount=0; log('observe: all cleared'); }
        // ===== script-object creation + field access (for building the native menu) =====
        // NO sig-scanned addresses (the JSON's CClass_CreateInstance hash is bogus on this binary - it points
        // at a parser). Instead use the CClass vtable, which we already call successfully (nameOf uses vt+0x10).
        // CClass vtable: SDK lists ConstructCls //D8, AllocMemory //E8, BUT the runtime vtable has a +0x08 shift
        // (virtual dtor takes TWO Itanium slots; confirmed: nameOf reads GetName at vt+0x10 though SDK says //08).
        // So runtime: ConstructCls @0xE0, AllocMemory @0xF0. CClass fields: parent@0x10, props@0x28, size@0x68.
        // createInstance = AllocMemory() (allocs sizeof from the class allocator) + ConstructCls(mem).
        function createInstance(className){ const cls=clsByName(className); if(!cls) return null;
            try{ const vt=cls.readPointer();
                const allocFn=new NativeFunction(vt.add(0xf0).readPointer(),'pointer',['pointer']);   // CClass::AllocMemory() (SDK 0xE8 +8)
                const mem=allocFn(cls); if(!mem||mem.isNull()){ log('createInstance: AllocMemory null'); return null; }
                const ctorFn=new NativeFunction(vt.add(0xe0).readPointer(),'void',['pointer','pointer']); // ConstructCls(mem) (SDK 0xD8 +8)
                ctorFn(cls, mem); return mem;
            }catch(e){ log('createInstance err '+e); return null; } }
        // Resolve a field -> {off, type, typeName} via the manual props walk (inheritance via parent chain). No game func.
        function findProp(className, fieldName){ let cls=clsByName(className); if(!cls) return null; const want=u64(fnv(fieldName)); let guard=0;
            while(cls&&!cls.isNull()&&guard++<12){ const pp=cls.add(0x28).readPointer(), n=cls.add(0x30).readU32();
                for(let i=0;i<n;i++){ const pr=pp.add(i*8).readPointer(); if(pr.isNull())continue;
                    if(pr.add(0x08).readU64().equals(want)){ let tn='?'; try{tn=nameOf(pr.readPointer());}catch(e){} return {prop:pr, off:pr.add(0x20).readU32(), type:pr.readPointer(), typeName:tn}; } }
                cls=cls.add(0x10).readPointer(); }
            return null; }
        // get an INSTANCE's class meta (instance vtable GetType @ +0x08), and resolve a method on a known meta.
        function instType(inst){ try{ const vt=inst.readPointer(); return new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(inst); }catch(e){ return null; } }
        function resolveFuncMeta(meta, method){ const mh=fnv(method); let cls=meta;
            while(cls&&!cls.isNull()){ for(const off of [0x48,0x58]){ const fp=cls.add(off).readPointer(); const n=cls.add(off+8).readU32();
                if(!fp.isNull()){ for(let i=0;i<n;i++){ const f=fp.add(i*8).readPointer(); if(f.isNull())continue;
                    if(f.add(0x10).readU64().equals(u64(mh))){ const rp=f.add(0x18).readPointer(); return {fn:f, retType:rp.isNull()?ptr(0):rp.readPointer()}; } } } }
                cls=cls.add(0x10).readPointer(); }
            return null; }
        // enum member value by enum-type-name-hash + member name
        function resolveEnumByTypeHash(typeHashHex, member){ ensureReg(); const en=GetEnum(reg,uint64(typeHashHex)); if(en.isNull()) return null;
            const hp=en.add(0x28).readPointer(), n=en.add(0x30).readU32(), vp=en.add(0x38).readPointer(); const mh=fnv(member);
            for(let i=0;i<n;i++){ if(hp.add(i*8).readU64().equals(u64(mh))) return vp.add(i*8).readU64(); } return null; }
        function fromTDBID(tb,out){ const bc=Memory.alloc(32);let o=0;bc.writeU8(0x11);o++;for(let i=0;i<8;i++){bc.add(o).writeU8(tb[i]);o++;}bc.add(o).writeU8(0x26);
            const fr=Memory.alloc(0x90);fr.writePointer(bc);fr.add(0x40).writePointer(fromtd?fromtd.ctx:ptr(0));return Exec(fromtd.fn,fromtd.ctx,fr,out,fromtd.retType); }
        // generic invoke: fn(CClassFunction*), ctx, args[] strings -> 16-byte result buffer
        function callFunc(fn, ctx, retType, args){
            const pEntries=fn.add(0x28).readPointer(); const pCount=fn.add(0x30).readU32();
            const locals=Memory.alloc(0x40+args.length*0x20); const props=[];
            for(let i=0;i<args.length;i++){ if(i>=pCount) throw 'too many args (fn takes '+pCount+')';
                const prop=pEntries.add(i*8).readPointer(); const ptype=prop.readPointer(); const tn=nameOf(ptype);
                const off=0x20+i*0x20; const dst=locals.add(off); const a=args[i];
                if(typeof a==='object'&&a.raw){ Memory.copy(dst, a.raw, a.n||16); }
                else if(a[0]==='@'){ let inst; if(a==='@player') inst=player; else if(a==='@self') inst=ctx; else inst=ptr(a.slice(1));
                    if(!inst||inst.isNull()) throw 'no instance for '+a; dst.writePointer(inst); dst.add(8).writePointer(refcnt); }
                else if(tn===T_ITEM){ fromTDBID(tdbidBytes(a),dst); }
                else if(tn===T_I32||tn===T_U32){ dst.writeU32(parseInt(a)>>>0); }
                else if(tn===T_I64||tn===T_U64){ dst.writeU64(uint64(parseInt(a))); }
                else if(tn===T_F32){ dst.writeFloat(parseFloat(a)); }
                else if(tn===T_BOOL){ dst.writeU8((a==='true'||a==='1')?1:0); }
                else if(tn===T_CNAME){ dst.writeU64(u64(fnv(a))); }
                else if(tn===T_TDB){ const tb=tdbidBytes(a); for(let k=0;k<8;k++) dst.add(k).writeU8(tb[k]); }
                else { let ev=resolveEnumByTypeHash(tn, a); if(ev===null && /^-?\d+$/.test(a)) ev=uint64(parseInt(a)); if(ev!==null){ dst.writeU64(ev); } else throw 'unsupported arg type '+tn+' for "'+a+'"'; }
                const cp=Memory.alloc(0x30); cp.writePointer(ptype); cp.add(0x20).writeU32(off); props.push(cp); }
            const bc=Memory.alloc(16+args.length*9); let o=0; for(let i=0;i<args.length;i++){ bc.add(o).writeU8(0x18);o++; bc.add(o).writePointer(props[i]);o+=8; } bc.add(o).writeU8(0x26);
            const fr=Memory.alloc(0x90); fr.writePointer(bc); fr.add(0x10).writePointer(locals); fr.add(0x18).writePointer(locals); fr.add(0x40).writePointer(ctx.isNull?(ctx):ctx);
            const res=Memory.alloc(16); res.writeU64(0); res.add(8).writeU64(0); Exec(fn, ctx, fr, res, retType); return res; }
        function instOf(className){ const m=clsByName(className); if(!m) return null; const fv=m.sub(base).add(FV0).toString(16); return instReg[fv]||null; }
        function doGive(name,qty,forceBulk){ const e=resolveFunc('gameTransactionSystem','GiveItem'); if(!e){ log('GiveItem not found'); return; }
            const tx=instOf('gameTransactionSystem'); if(!tx){ log('no transaction system instance yet'); return; }
            const owner=authPlayer();   // authoritative local player (deterministic; avoids flaky transient puppets)
            const give=function(q){ const id=Memory.alloc(16); id.writeU64(0); id.add(8).writeU64(0); fromTDBID(tdbidBytes(name),id);
                return callFuncRaw(e.fn, tx, e.retType, [{kind:'handle',inst:owner},{kind:'item16',ptr:id},{kind:'i32',v:q}]); };
            let ok=0;
            // GiveItem's quantity arg is only honored for currency (money). For normal items it adds 1
            // regardless, so loop give(1) N times to actually deposit the requested count. Cap to avoid hangs.
            if(forceBulk){ ok=give(qty).readU8(); log('give '+name+' x'+qty+' (bulk) -> '+ok); }
            else { const n=Math.min(qty,9999); for(let k=0;k<n;k++){ if(give(1).readU8()) ok++; } log('give '+name+' x'+n+' -> '+ok+'/'+n); }
            if(!ok) log('  (0 added - bad item id? names start with "Items." e.g. Items.Preset_Lexington_Default)'); }
        // raw marshaller (pre-encoded values) for give chaining
        function callFuncRaw(fn, ctx, retType, items){ const pEntries=fn.add(0x28).readPointer();
            const locals=Memory.alloc(0x40+items.length*0x20); const props=[];
            for(let i=0;i<items.length;i++){ const prop=pEntries.add(i*8).readPointer(); const ptype=prop.readPointer(); const off=0x20+i*0x20; const dst=locals.add(off); const it=items[i];
                if(it.kind==='handle'){ dst.writePointer(it.inst); dst.add(8).writePointer(refcnt); }
                else if(it.kind==='item16'){ Memory.copy(dst, it.ptr, 16); }
                else if(it.kind==='i32'){ dst.writeU32(it.v>>>0); }
                const cp=Memory.alloc(0x30); cp.writePointer(ptype); cp.add(0x20).writeU32(off); props.push(cp); }
            const bc=Memory.alloc(16+items.length*9); let o=0; for(let i=0;i<items.length;i++){ bc.add(o).writeU8(0x18);o++; bc.add(o).writePointer(props[i]);o+=8; } bc.add(o).writeU8(0x26);
            const fr=Memory.alloc(0x90); fr.writePointer(bc); fr.add(0x10).writePointer(locals); fr.add(0x18).writePointer(locals); fr.add(0x40).writePointer(ctx);
            const res=Memory.alloc(16); res.writeU64(0); res.add(8).writeU64(0); Exec(fn, ctx, fr, res, retType); return res; }
        function sane(pp){ try{ return !pp.isNull() && pp.compare(ptr('0x10000'))>0 && pp.compare(ptr('0x800000000000'))<0; }catch(e){ return false; } }
        function getSystem(giBuf, className){    // giBuf = GetGame result buffer (a GameInstance wrapper)
            const cls=clsByName(className); if(!cls){ log('  class '+className+' not found'); return null; }
            for(const goff of [8, 0]){           // gameInstance ptr lives at wrapper+8 (per game's own code); fallback +0
                try{
                    const gi=giBuf.add(goff).readPointer(); if(!sane(gi)) continue;
                    const holder=gi.add(0x48).readPointer(); if(!sane(holder)) continue;
                    const cpp=holder.add(0xc0).readPointer(); if(!sane(cpp)) continue;
                    const container=cpp.readPointer(); if(!sane(container)) continue;
                    const cvt=container.readPointer(); if(!sane(cvt)) continue;
                    const getFn=new NativeFunction(cvt.add(0x10).readPointer(),'pointer',['pointer','pointer']);
                    const sys=getFn(container, cls); log('  getSystem('+className+') gi(+'+goff+')='+gi+' container='+container+' -> '+sys);
                    if(!sys.isNull()) return sys;
                }catch(e){ log('  getSystem gi+'+goff+' err: '+e); }
            }
            return null;
        }
        function probeFuncs(className, names){ for(const nm of names){ const e=resolveFunc(className,nm);
            if(e) log('    '+className+'.'+nm+' FOUND '+(e.isStatic?'[static]':'[inst]')+' ret='+(e.retType.isNull()?'void':nameOf(e.retType))+' '+sigStr(e.fn));
            else log('    '+className+'.'+nm+' (none)'); } }
        function resolveAny(classNames, method){ for(const c of classNames){ const e=resolveFunc(c,method); if(e){ e.cls=c; return e; } } return null; }
        // Get a scriptable system the way the VM does: GameInstance.GetScriptableSystemsContainer(gi).Get(name)
        function getScriptableSystem(giRes, sysName){
            const gsc=resolveAny(['GameInstance','ScriptGameInstance','gameScriptGameInstance'],'GetScriptableSystemsContainer');
            if(!gsc){ log('  GetScriptableSystemsContainer not found'); return null; }
            log('  GSC ['+gsc.cls+(gsc.isStatic?' static':' inst')+'] '+sigStr(gsc.fn));
            let cont=null;
            for(const nb of [8,16]){ try{ const r=callFunc(gsc.fn, player, gsc.retType, [{raw:giRes,n:nb}]);
                const c=r.readPointer(); log('  container(gi'+nb+')='+c); if(sane(c)){ cont=c; break; } }catch(e){ log('  GSC(gi'+nb+') err: '+e); } }
            if(!cont) return null;
            const get=resolveAny(['ScriptableSystemsContainer','gameScriptableSystemsContainer'],'Get');
            if(!get){ log('  container.Get not found'); return null; }
            log('  Get ['+get.cls+'] '+sigStr(get.fn));
            try{ const r=callFunc(get.fn, cont, get.retType, [sysName]); const sys=r.readPointer(); log('  '+sysName+' inst='+sys); return sane(sys)?sys:null; }
            catch(e){ log('  Get err: '+e); return null; }
        }
        // The owner the dev-data is keyed to is the local player puppet (one of several captured puppets
        // share its vtable). We can't pull it from the scriptable container (PlayerSystem isn't there),
        // so we probe owner candidates against GetDevelopmentData and cache the one that yields data.
        function getDevData(){
            const gg=resolveFunc('PlayerPuppet','GetGame'); if(!gg){ log('GetGame not found'); return null; }
            const giRes=callFunc(gg.fn, player, gg.retType, []);
            const sys=getScriptableSystem(giRes,'PlayerDevelopmentSystem');
            if(!sys){ log('could not get PlayerDevelopmentSystem instance'); return null; }
            const gdd=resolveFunc('PlayerDevelopmentSystem','GetDevelopmentData'); if(!gdd){ log('GetDevelopmentData not found'); return null; }
            const owners=[]; const ap=authPlayer(giRes); if(ap) owners.push(ap);   // authoritative local player first
            if(devOwner) owners.push(devOwner); if(player) owners.push(player); for(const c of playerCands) owners.push(c);
            const tried=new Set();
            for(const o of owners){ const k=o.toString(); if(tried.has(k)) continue; tried.add(k);
                try{ const r=callFunc(gdd.fn, sys, gdd.retType, ['@'+o]); const d=r.readPointer();
                    if(sane(d)){ devOwner=o; log('  devData='+d+' (owner '+o+', tried '+tried.size+')'); return d; } }
                catch(e){ log('  GetDevelopmentData('+o+') err: '+e); } }
            devOwner=null; log('  GetDevelopmentData: no owner of '+tried.size+' yielded data'); return null;
        }
        // ---- convenience-command helpers ----
        function getGI(){ const gg=resolveFunc('PlayerPuppet','GetGame'); if(!gg) return null; return callFunc(gg.fn, player, gg.retType, []); }
        function curPlayer(){ return devOwner||player; }
        // authoritative, deterministic local player (cpPlayerSystem.GetLocalPlayerControlledGameObject); falls back to captured
        function authPlayer(gi){ try{ gi=gi||getGI(); if(gi){ const p=getPlayerViaSystem(gi); if(p) return p; } }catch(e){} return curPlayer(); }
        // call a static GameInstance.<getter>(gi) -> system/facility ptr (same pattern as GetScriptableSystemsContainer)
        function getViaGetter(giRes, getterName){
            const g=resolveAny(['ScriptGameInstance','GameInstance','gameScriptGameInstance'], getterName);
            if(!g){ log('  getter '+getterName+' not found'); return null; }
            log('  '+getterName+' '+(g.isStatic?'[static]':'[inst]')+' '+sigStr(g.fn));
            for(const nb of [8,16]){ try{ const r=callFunc(g.fn, player, g.retType, [{raw:giRes,n:nb}]); const p=r.readPointer(); if(sane(p)) return p; }catch(e){ log('  '+getterName+'(gi'+nb+') err: '+e); } }
            return null;
        }
        // Authoritative local player via GameInstance.GetPlayerSystem(gi).<localPlayerGetter>() (probes the name).
        let _pgetter=null;
        function getPlayerViaSystem(gi){
            const ps=getViaGetter(gi,'GetPlayerSystem'); if(!ps){ log('  GetPlayerSystem not reachable'); return null; }
            const names=_pgetter?[_pgetter]:['GetLocalPlayerControlledGameObject','GetLocalPlayerMainGameObject','GetLocalPlayer','GetPlayerControlledGameObject','GetPlayer'];
            for(const cls of ['gamePlayerSystem','cpPlayerSystem','PlayerSystem']){
                for(const mn of names){ const m=resolveFunc(cls,mn); if(!m) continue;
                    try{ const r=callFunc(m.fn, ps, m.retType, []); const o=r.readPointer(); log('  '+cls+'.'+mn+' -> '+o); if(sane(o)){ _pgetter=mn; return o; } }
                    catch(e){ log('  '+cls+'.'+mn+' err '+e); } }
            }
            log('  no local-player getter resolved on the player system'); return null;
        }
        // godmode via the IsInvulnerable STAT (not the god-mode system). The damage pipeline's
        // InvulnerabilityCheck flags DealNoDamage when GetStatValue(player, IsInvulnerable) > 0. We grant it
        // with a +1 stat modifier through the StatsSystem (which responds to our entity id, like heal does).
        // Note: fall damage / scripted kills carry IgnoreImmortalityModes and bypass ALL god mode by design.
        // Apply/remove a status effect on the player (the proven CET approach for godmode/invisibility/etc).
        // ApplyStatusEffect(objID: entEntityID, statusEffectID: TweakDBID, ...rest optional - the VM defaults them).
        function statusApply(on, effectID){
            const gi=getGI(); if(!gi) return false;
            const p=authPlayer(gi); if(!p) return false;
            const geid=resolveAny(['gameObject','gameEntity'],'GetEntityID'); if(!geid) return false;
            const eid=callFunc(geid.fn, p, geid.retType, []);
            const ses=getSystemFlexible(gi,'gameStatusEffectSystem','GetStatusEffectSystem'); if(!ses) return false;
            const e=resolveAny(['gameStatusEffectSystem'], on?'ApplyStatusEffect':'RemoveStatusEffect'); if(!e) return false;
            try{ callFunc(e.fn, ses, e.retType, [{raw:eid,n:8}, effectID]); return true; }
            catch(ex){ log('status err: '+ex); return false; }
        }
        // Toggle a player status effect, reapplying on a tick (the game strips these on some transitions).
        const statusToggles={};   // effectID -> { on, timer }
        function toggleStatus(label, effectID, on){
            const st=statusToggles[effectID]||(statusToggles[effectID]={on:false,timer:null});
            st.on=on;
            const ok=statusApply(on, effectID);
            if(on){
                log('*** '+label+' '+(ok?'ON':'failed - StatusEffectSystem not reachable')+' ***');
                if(ok && !st.timer){ st.timer=setInterval(function(){ if(st.on) statusApply(true, effectID); }, 3000); }
            } else {
                if(st.timer){ clearInterval(st.timer); st.timer=null; }
                log('*** '+label+' '+(ok?'OFF':'off (StatusEffectSystem not reachable)')+' ***');
            }
        }
        function doGodmode(on){ toggleStatus('godmode', 'BaseStatusEffect.Invulnerable', on); }
        function doInfammo(on){ toggleStatus('infinite ammo', 'GameplayRestriction.InfiniteAmmo', on); }
        function doInvisible(on){
            toggleStatus('invisible', 'BaseStatusEffect.Cloaked', on);
            // Cloaked is only the visual camo; SetInvisible() is what actually breaks enemy detection.
            try{ const gi=getGI(); const p=authPlayer(gi);
                const si=resolveAny(['gameObject','gameEntity'],'SetInvisible'); if(si) callFunc(si.fn, p, si.retType, [on?'true':'false']);
                const uv=resolveAny(['gameObject','gameEntity'],'UpdateVisibility'); if(uv) callFunc(uv.fn, p, uv.retType, []);
            }catch(e){ log('invis visibility err: '+e); }
        }
        // --- world / misc cheats ---
        function doTime(h,m){
            const gi=getGI(); if(!gi){ log('time: no gi'); return; }
            const ts=getViaGetter(gi,'GetTimeSystem'); if(!ts){ log('time: TimeSystem not reachable'); return; }
            const e=resolveAny(['gameTimeSystem'],'SetGameTimeByHMS'); if(!e){ log('time: SetGameTimeByHMS not found'); return; }
            try{ callFunc(e.fn, ts, e.retType, [''+h, ''+m, '0']); log('*** time set to '+h+':'+(m<10?'0':'')+m+' ***'); }
            catch(ex){ log('time err: '+ex); }
        }
        function doSlowmo(on, factor){
            const gi=getGI(); if(!gi){ log('slowmo: no gi'); return; }
            const ts=getViaGetter(gi,'GetTimeSystem'); if(!ts){ log('slowmo: TimeSystem not reachable'); return; }
            if(on){ const e=resolveAny(['gameTimeSystem'],'SetTimeDilation'); if(!e){ log('slowmo: SetTimeDilation not found'); return; }
                try{ callFunc(e.fn, ts, e.retType, ['NightCityConsole', ''+(factor||0.3)]); log('*** slowmo ON ('+(factor||0.3)+'x) ***'); }catch(ex){ log('slowmo err: '+ex); } }
            else { const e=resolveAny(['gameTimeSystem'],'UnsetTimeDilation'); if(!e){ log('slowmo: UnsetTimeDilation not found'); return; }
                try{ callFunc(e.fn, ts, e.retType, ['NightCityConsole']); log('*** slowmo OFF ***'); }catch(ex){ log('slowmo err: '+ex); } }
        }
        function doNoPolice(on){
            const gi=getGI(); if(!gi){ log('nopolice: no gi'); return; }
            const p=authPlayer(gi); if(!p){ log('nopolice: no player'); return; }
            const gp=resolveAny(['gameObject','PlayerPuppet','gameEntity'],'GetPreventionSystem'); if(!gp){ log('nopolice: GetPreventionSystem not found'); return; }
            let ps=null; try{ ps=callFunc(gp.fn, p, gp.retType, []).readPointer(); }catch(ex){ log('nopolice: GetPreventionSystem err: '+ex); return; }
            if(!sane(ps)){ log('nopolice: no PreventionSystem instance'); return; }
            const e=resolveAny(['PreventionSystem','gamePreventionSystem'],'TogglePreventionSystem'); if(!e){ log('nopolice: TogglePreventionSystem not found'); return; }
            try{ callFunc(e.fn, ps, e.retType, [on?'false':'true']); log('*** police '+(on?'DISABLED':'enabled')+' ***'); }
            catch(ex){ log('nopolice err: '+ex); }
        }
        function doLevel(n){
            const dd=getDevData(); if(!dd){ log('level: no PlayerDevelopmentData'); return; }
            const sl=resolveAny(['PlayerDevelopmentData'],'SetLevel'); if(!sl){ log('level: SetLevel not found'); return; }
            log('  SetLevel '+sigStr(sl.fn));
            // (gamedataProficiencyType, Int32 level, telemetryLevelGainReason, Bool)
            try{ callFunc(sl.fn, dd, sl.retType, ['Level', ''+n, '0', 'true']); log('*** level set to '+n+' ***'); }
            catch(e){ log('level err: '+e); }
        }
        // street cred rides the same PlayerDevelopmentData.SetLevel path as level - only the
        // gamedataProficiencyType member differs ('StreetCred' vs 'Level'). Caps at 50; SetLevel clamps.
        function doStreetCred(n){
            const dd=getDevData(); if(!dd){ log('streetcred: no PlayerDevelopmentData'); return; }
            const sl=resolveAny(['PlayerDevelopmentData'],'SetLevel'); if(!sl){ log('streetcred: SetLevel not found'); return; }
            try{ callFunc(sl.fn, dd, sl.retType, ['StreetCred', ''+n, '0', 'true']); log('*** street cred set to '+n+' ***'); }
            catch(e){ log('streetcred err: '+e); }
        }
        const tpMarks={};   // name -> ArrayBuffer(16) saved Vector4 (session-only)
        function doTeleport(t){
            const gi=getGI(); if(!gi){ log('teleport: no GameInstance'); return; }
            const p=authPlayer(gi); if(!p){ log('teleport: no player'); return; }
            const gw=resolveAny(['gameObject','gameEntity'],'GetWorldPosition'); if(!gw){ log('teleport: GetWorldPosition not found'); return; }
            const cur=callFunc(gw.fn, p, gw.retType, []);   // current Vector4 (16B)
            const cx=cur.readFloat(), cy=cur.add(4).readFloat(), cz=cur.add(8).readFloat();
            const sub=t[1];
            if(sub==='save'&&t[2]){ tpMarks[t[2]]=cur.readByteArray(16); log('teleport: saved "'+t[2]+'" @ '+cx.toFixed(1)+','+cy.toFixed(1)+','+cz.toFixed(1)); return; }
            if(!sub){ log('current: x='+cx.toFixed(2)+' y='+cy.toFixed(2)+' z='+cz.toFixed(2)+'  | saved: ['+(Object.keys(tpMarks).join(', ')||'none')+']  | use: teleport <x> <y> <z> | teleport save <name> | teleport <name>'); return; }
            const dst=Memory.alloc(16); Memory.copy(dst,cur,16);   // base on current (preserves w)
            if(!isNaN(parseFloat(sub)) && t.length>=4){ dst.writeFloat(parseFloat(t[1])); dst.add(4).writeFloat(parseFloat(t[2])); dst.add(8).writeFloat(parseFloat(t[3])); }
            else if(tpMarks[sub]){ dst.writeByteArray(tpMarks[sub]); }
            else { log('teleport: "'+sub+'" is not coords or a saved name (try: teleport save '+sub+')'); return; }
            const fac=getViaGetter(gi,'GetTeleportationFacility'); if(!fac){ log('teleport: GetTeleportationFacility not reachable'); return; }
            const tp=resolveAny(['gameTeleportationFacility'],'Teleport'); if(!tp){ log('teleport: Teleport not found'); return; }
            const rot=Memory.alloc(16); rot.writeU64(0); rot.add(8).writeU64(0);   // EulerAngles 0,0,0
            try{ callFunc(tp.fn, fac, tp.retType, ['@'+p, {raw:dst,n:16}, {raw:rot,n:12}]);
                log('*** teleported to '+dst.readFloat().toFixed(1)+','+dst.add(4).readFloat().toFixed(1)+','+dst.add(8).readFloat().toFixed(1)+' ***'); }
            catch(e){ log('teleport err: '+e); }
        }
        // get a system from the scriptable container OR via a static GameInstance.GetXxx(gi) getter
        function getSystemFlexible(gi, scriptName, getterName){
            let s=getScriptableSystem(gi, scriptName); if(s) return s;
            if(getterName){ s=getViaGetter(gi, getterName); if(s) return s; }
            return null;
        }
        function doRemove(name,qty){
            const e=resolveFunc('gameTransactionSystem','RemoveItem'); if(!e){ log('RemoveItem not found'); return; }
            const tx=instOf('gameTransactionSystem'); if(!tx){ log('no transaction system instance yet'); return; }
            const id=Memory.alloc(16); id.writeU64(0); id.add(8).writeU64(0); fromTDBID(tdbidBytes(name),id);
            try{ const r=callFuncRaw(e.fn, tx, e.retType, [{kind:'handle',inst:authPlayer()},{kind:'item16',ptr:id},{kind:'i32',v:qty}]);
                const ok=r.readU8(); log('remove '+name+' x'+qty+' -> '+ok); if(!ok) log('  (not removed - bad item id, or you don\'t have it; names start with "Items.")'); }catch(ex){ log('remove err: '+ex); }
        }
        function doSetFact(name, val){
            const gi=getGI(); if(!gi){ log('setfact: no GameInstance'); return; }
            const qs=getSystemFlexible(gi,'questQuestsSystem','GetQuestsSystem'); if(!qs){ log('setfact: QuestsSystem not reachable'); return; }
            const e=resolveAny(['questQuestsSystem'],'SetFact'); if(!e){ log('setfact: SetFact not found'); return; }
            try{ callFunc(e.fn, qs, e.retType, [name, ''+val]); log('*** setfact '+name+' = '+val+' ***'); }catch(ex){ log('setfact err: '+ex); }
        }
        function doHeal(){
            const gi=getGI(); if(!gi){ log('heal: no GameInstance'); return; }
            const sps=getSystemFlexible(gi,'gameStatPoolsSystem','GetStatPoolsSystem'); if(!sps){ log('heal: StatPoolsSystem not reachable'); return; }
            const p=authPlayer(gi); if(!p){ log('heal: no player'); return; }
            const geid=resolveAny(['gameObject','gameEntity'],'GetEntityID'); if(!geid){ log('heal: GetEntityID not found'); return; }
            const eid=callFunc(geid.fn,p,geid.retType,[]);
            const rs=resolveAny(['gameStatPoolsSystem'],'RequestSettingStatPoolValue'); if(!rs){ log('heal: RequestSettingStatPoolValue not found'); return; }
            // (gameStatsObjectID, gamedataStatPoolType 'Health', Float value, source(null), Bool, Bool)
            // The pool value is ABSOLUTE points (~1816 at high levels), not a 0-100 percentage, so 100
            // under-heals badly. Set a value far above any max; the pool clamps it to the real max (full).
            const src=Memory.alloc(16);   // zeroed null source
            try{ callFunc(rs.fn, sps, rs.retType, [{raw:eid,n:8},'Health','1000000',{raw:src,n:16},'false','false']); log('*** heal: Health set to full ***'); }
            catch(e){ log('heal err: '+e); }
        }
        function doSummon(){
            const gi=getGI(); if(!gi){ log('summon: no GameInstance'); return; }
            const vs=getSystemFlexible(gi,'gameVehicleSystem','GetVehicleSystem'); if(!vs){ log('summon: VehicleSystem not reachable'); return; }
            const e=resolveAny(['gameVehicleSystem'],'ToggleSummonMode'); if(!e){ log('summon: ToggleSummonMode not found'); return; }
            try{ callFunc(e.fn, vs, e.retType, []); log('*** toggled vehicle summon mode ***'); }catch(ex){ log('summon err: '+ex); }
        }
        // read-only recon: logs exact signatures for the commands still to build (inventory/stats/facts/world)
        function convdump(){ log('=== CONVDUMP ===');
            probeFuncs('gameIQuestsSystem',['SetFact','GetFact','SetFactStr']);
            probeFuncs('questQuestsSystem',['SetFact','GetFact']);
            probeFuncs('EquipmentSystem',['EquipItem','UnequipItem']);
            probeFuncs('EquipmentSystemPlayerData',['EquipItem','UnequipItem','EquipItemInSlot']);
            probeFuncs('gamePlayerSystem',['GetLocalPlayerControlledGameObject','GetLocalPlayerMainGameObject','GetLocalPlayer','GetPlayerControlledGameObject','GetPlayer']);
            probeFuncs('gameTransactionSystem',['GiveItem','RemoveItem','HasItem','RemoveItemFromInventory','GetItemQuantity']);
            probeFuncs('gameEquipmentSystem',['EquipItem','UnequipItem','GetItemInEquipSlot']);
            probeFuncs('gameStatsSystem',['GetStatValue','GetStatBonusMultiplier']);
            probeFuncs('gameStatPoolsSystem',['GetStatPoolValue','RequestSettingStatPoolMinValue','RequestChangingStatPoolValue','RequestSettingStatPoolValue']);
            probeFuncs('QuestsSystem',['SetFact','GetFact','SetFactStr']);
            probeFuncs('gameVehicleSystem',['TogglePlayerActiveVehicle','EnablePlayerVehicle','SpawnPlayerVehicle','ToggleSummonMode']);
            probeFuncs('gameGodModeSystem',['AddGodMode','RemoveGodMode','HasGodMode']);
            probeFuncs('PlayerDevelopmentData',['AddExperience','SetLevel','GetProficiencyLevel']);
            try{ const p=curPlayer(); const gw=resolveAny(['gameObject','gameEntity'],'GetWorldPosition');
                if(gw&&p){ const r=callFunc(gw.fn,p,gw.retType,[]); log('  player WorldPosition(16B)='+hexp(r,16)); } }catch(e){ log('  pos err: '+e); }
        }
        function addPoints(n, member){
            const devData=getDevData(); if(!devData){ return; }
            const adp=resolveFunc('PlayerDevelopmentData','AddDevelopmentPoints'); if(!adp){ log('AddDevelopmentPoints not found'); return; }
            log('  AddDevelopmentPoints '+sigStr(adp.fn));
            try{ callFunc(adp.fn, devData, adp.retType, [''+n, member]); log('*** '+member+' points +'+n+' DONE ***'); }
            catch(e){ log('AddDevelopmentPoints err: '+e); } }
        // Resolve PlayerDevelopmentData through the live player/system chain instead of relying on the
        // generic call command's player fallback. Refuse to invoke a changed/overloaded signature.
        function resetDevelopment(method, label){
            const devData=getDevData(); if(!devData){ log(label+': no PlayerDevelopmentData; load a save and retry'); return; }
            const reset=resolveFunc('PlayerDevelopmentData',method); if(!reset){ log(label+': '+method+' not found'); return; }
            if(reset.isStatic){ log(label+': refusing '+method+'; expected an instance method'); return; }
            let count; try{ count=reset.fn.add(0x30).readU32(); }catch(e){ log(label+': could not inspect '+method+' signature'); return; }
            if(count!==0){ log(label+': refusing '+method+'; expected 0 params, found '+count); return; }
            try{ callFunc(reset.fn, devData, reset.retType, []); log('*** '+label+' reset DONE ***'); }
            catch(e){ log(label+' reset err: '+e); }
        }
        // ===== Phase 2 recon: identify the Metal present path (raw libobjc; Frida ObjC bridge is absent) =====
        let mrArmed=false, mrCap=false, _objc=null, _expCache={};
        function resolveExport(name){ if(_expCache[name]!==undefined) return _expCache[name]; let r=null;
            try{ if(typeof Module!=='undefined'){
                if(typeof Module.findExportByName==='function'){ const p=Module.findExportByName(null,name); if(p&&!p.isNull()) r=p; }
                if(!r&&typeof Module.getExportByName==='function'){ try{ const p=Module.getExportByName(null,name); if(p&&!p.isNull()) r=p; }catch(e){} }
            }}catch(e){}
            if(!r){ try{ const mods=Process.enumerateModules(); for(const m of mods){ try{ if(typeof m.findExportByName==='function'){ const p=m.findExportByName(name); if(p&&!p.isNull()){ r=p; break; } } }catch(e){} } }catch(e){} }
            if(!r){ try{ const mods=Process.enumerateModules(); for(const m of mods){ const mn=m.name||''; if(mn.indexOf('libobjc')<0&&mn.indexOf('libsystem')<0) continue; let exps=null; try{ exps=(typeof m.enumerateExports==='function')?m.enumerateExports():(typeof Module.enumerateExports==='function'?Module.enumerateExports(mn):null); }catch(e){}
                if(exps){ for(const e of exps){ if(e.name===name){ r=e.address; break; } } } if(r) break; } }catch(e){} }
            _expCache[name]=r; return r; }
        function objcRT(){ if(_objc) return _objc;
            const f=(n,r,a)=>{ const p=resolveExport(n); return p?new NativeFunction(p,r,a):null; };
            const o={ getClass:f('objc_getClass','pointer',['pointer']), selReg:f('sel_registerName','pointer',['pointer']),
                cgim:f('class_getInstanceMethod','pointer',['pointer','pointer']), mgi:f('method_getImplementation','pointer',['pointer']),
                copyList:f('objc_copyClassList','pointer',['pointer']), cname:f('class_getName','pointer',['pointer']),
                msgP:f('objc_msgSend','pointer',['pointer','pointer']), msgU:f('objc_msgSend','uint64',['pointer','pointer']),
                msgB:f('objc_msgSend','bool',['pointer','pointer']) };
            o.cls=(n)=>o.getClass(Memory.allocUtf8String(n)); o.sel=(n)=>o.selReg(Memory.allocUtf8String(n));
            _objc=o; return o; }
        function metalRecon(){
            log('METALRECON: api Module.findExportByName='+(typeof Module!=='undefined'&&typeof Module.findExportByName)+' Module.enumerateExports='+(typeof Module!=='undefined'&&typeof Module.enumerateExports)+' Process.enumerateModules='+(typeof Process!=='undefined'&&typeof Process.enumerateModules));
            const o=objcRT();
            if(!o.getClass||!o.msgP){ log('METALRECON: libobjc exports unresolved (objc_getClass='+(resolveExport('objc_getClass')||'null')+' objc_msgSend='+(resolveExport('objc_msgSend')||'null')+')'); return; }
            log('METALRECON: libobjc OK. CAMetalLayer='+(!o.cls('CAMetalLayer').isNull())+' MTLCreateSystemDefaultDevice='+(!!resolveExport('MTLCreateSystemDefaultDevice')));
            // Enumerate command-buffer classes that respond to presentDrawable: (candidate present-hook points)
            try{ const cnt=Memory.alloc(4); const arr=o.copyList(cnt); const n=cnt.readU32(); const psel=o.sel('presentDrawable:'); let hits=[];
                for(let i=0;i<n && hits.length<24;i++){ const c=arr.add(i*8).readPointer(); if(c.isNull()) continue; let nm=''; try{ nm=o.cname(c).readUtf8String(); }catch(e){ continue; }
                    if(nm && nm.indexOf('CommandBuffer')>=0){ const m=o.cgim(c, psel); if(!m.isNull()) hits.push(nm); } }
                log('METALRECON: CommandBuffer classes (count '+n+' total) w/ presentDrawable:: '+(hits.join(', ')||'(none)')); }
            catch(e){ log('METALRECON: class enum err: '+e); }
            // One-shot hook on -[CAMetalLayer nextDrawable] IMP to capture layer device/format/size + drawable texture
            if(mrArmed){ log('METALRECON: already armed (cap='+mrCap+')'); return; }
            try{ const cm=o.cls('CAMetalLayer'); if(cm.isNull()){ log('METALRECON: CAMetalLayer class not found'); return; }
                const meth=o.cgim(cm, o.sel('nextDrawable')); if(meth.isNull()){ log('METALRECON: nextDrawable method not found'); return; }
                const imp=o.mgi(meth); log('METALRECON: nextDrawable IMP='+imp);
                const sDev=o.sel('device'), sPix=o.sel('pixelFormat'), sFb=o.sel('framebufferOnly'), sTex=o.sel('texture'),
                      sW=o.sel('width'), sH=o.sel('height'), sName=o.sel('name'), sUtf=o.sel('UTF8String');
                Interceptor.attach(imp, {
                    onEnter:function(a){ this.self=a[0]; },
                    onLeave:function(ret){ if(mrCap) return; mrCap=true;
                        try{ const layer=this.self; const dev=o.msgP(layer,sDev); let devName='?'; try{ const ns=o.msgP(dev,sName); const cs=o.msgP(ns,sUtf); devName=cs.readUtf8String(); }catch(e){}
                            log('METALRECON FRAME: layer='+layer+' device='+dev+'('+devName+') pixelFormat='+o.msgU(layer,sPix).toString()+' framebufferOnly='+o.msgB(layer,sFb));
                            if(!ret.isNull()){ const tex=o.msgP(ret,sTex); log('METALRECON FRAME: drawable='+ret+' tex='+tex+' tex.pixelFormat='+o.msgU(tex,sPix).toString()+' '+o.msgU(tex,sW).toString()+'x'+o.msgU(tex,sH).toString()); }
                        }catch(e){ log('METALRECON FRAME cap err: '+e); } }
                });
                mrArmed=true; log('METALRECON: nextDrawable hook armed - capturing next frame');
            }catch(e){ log('METALRECON: hook err: '+e); }
        }
        // Translate common CET copy-paste one-liners into our commands (so internet snippets paste directly).
        function cetTranslate(line){ let m;
            // Game.AddToInventory("Items.X" [, qty])   -- by far the most copy-pasted CET call
            m=line.match(/^Game\.AddToInventory\(\s*['"]([A-Za-z0-9_.]+)['"]\s*(?:,\s*([0-9]+))?\s*\)\s*;?\s*$/);
            if(m) return 'give '+m[1]+' '+(m[2]||'1');
            return null; }
        function luaRespond(seq, type, val){ try{ var f=new File(LRES,'w'); f.write(seq+'\t'+type+'\t'+val+'\n'); f.flush(); f.close(); }catch(e){} }
        // Runs on the Frida poller thread (NOT via pendingQ) so it never deadlocks against the overlay's
        // render-thread block. It must therefore do only thread-safe reads (no executor/game-fn calls):
        // GetPlayer returns the cached `player` handle. Methods needing a real call wait for Q8 dispatch.
        function handleLuaCall(raw){   // raw = "lua-call \t seq \t method \t nargs \t arg1 \t ..."
            const p=raw.split('\t'); const seq=p[1], method=p[2];
            try{
                if(method==='GetPlayer'||method==='GetPlayerControlledGameObject'){ if(player&&!player.isNull()) luaRespond(seq,'ptr','0x'+player.toString(16)); else luaRespond(seq,'nil',''); return; }
                luaRespond(seq,'err','Game.'+method+'() needs main-thread dispatch (wired in Q8+); Q7 proves the bridge via GetPlayer');
            }catch(e){ luaRespond(seq,'err',''+e); }
        }
        function execute(line){ let raw=line.trim();
            if(raw.indexOf('lua-call\t')===0){ handleLuaCall(raw); return; }   // Q7 bridge: handle before the generic whitespace split
            const ct=cetTranslate(raw); if(ct){ log('(cet) '+raw+'  ->  '+ct); raw=ct; }
            const t=raw.split(/\s+/);
            if(t[0]==='metalrecon'){ metalRecon(); return; }   // Phase-2 recon: works at menu too
            if(t[0]==='tweakload'){ try{ var ex=resolveExport('cybermodman_tweakReload'); if(!ex||ex.isNull()){ log('tweakload: cybermodman_tweakReload export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('tweakload: cybermodman_tweakReload() called - check TweakXL.log'); }catch(e){ log('tweakload err '+e); } return; }   // exempt from in-game guard (drives TweakXL apply)
            if(t[0]==='tweakdumpflat'&&t[1]&&t[2]){ try{ var ex=resolveExport('cybermodman_tweakDumpFlat'); if(!ex||ex.isNull()){ log('tweakdumpflat: export NOT FOUND'); return; } var sr=Memory.allocUtf8String(t[1]); var spp=Memory.allocUtf8String(t[2]); new NativeFunction(ex,'void',['pointer','pointer'])(sr,spp); log('tweakdumpflat: '+t[1]+'.'+t[2]+' -> /tmp/tweakxl_dump.txt'); }catch(e){ log('tweakdumpflat err '+e); } return; }   // dump ONE flat by exact <Record> <prop>
            if(t[0]==='cmnreload'){ try{ var n=cmnLoad(); log('cmnreload: loaded '+n+' custom name(s); see /tmp/cybermodman_names.log'); }catch(e){ log('cmnreload err '+e); } return; }   // hot-reload cybermodman_names.json
            if(t[0]==='archiveload'){ try{ var ex=resolveExport('cybermodman_archiveReload'); if(!ex||ex.isNull()){ log('archiveload: cybermodman_archiveReload export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveload: cybermodman_archiveReload() called - check ArchiveXL.log'); }catch(e){ log('archiveload err '+e); } return; }   // drives ArchiveXL extension bring-up
            if(t[0]==='archiveprobe'){ try{ var ex=resolveExport('cybermodman_archiveProbeLoadTexts'); if(!ex||ex.isNull()){ log('archiveprobe: cybermodman_archiveProbeLoadTexts export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveprobe: cybermodman_archiveProbeLoadTexts() called - check ArchiveXL.log'); }catch(e){ log('archiveprobe err '+e); } return; }   // wall-B probe: drive LoadTexts directly
            if(t[0]==='archiveinject'){ try{ var ex=resolveExport('cybermodman_archiveInjectName'); if(!ex||ex.isNull()){ log('archiveinject: cybermodman_archiveInjectName export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveinject: cybermodman_archiveInjectName() called - check ArchiveXL.log'); }catch(e){ log('archiveinject err '+e); } return; }   // wall-B exp: overwrite live onscreens text
            if(t[0]==='archivehookname'){ try{ var ex=resolveExport('cybermodman_archiveHookName'); if(!ex||ex.isNull()){ log('archivehookname: cybermodman_archiveHookName export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archivehookname: cybermodman_archiveHookName() called - check ArchiveXL.log'); }catch(e){ log('archivehookname err '+e); } return; }   // wall-B exp: hook item display-name resolver
            if(t[0]==='archivename'){ try{ if(nameHookInstalled){ log('archivename: already installed'); return; } var naddr=base.add(0x378a4b8); var ncalls=0; Interceptor.attach(naddr,{ onEnter:function(a){ this.sret=this.context.x8; }, onLeave:function(r){ try{ var b=this.sret; if(!b||b.isNull()) return; var len=b.add(0x14).readU32(); var heap=(len&0x40000000)!==0; var alen=len&0x3FFFFFFF; var tp=heap?b.readPointer():b; var txt=''; try{ txt=tp.readUtf8String(alen); }catch(e){} if(ncalls<25){ ncalls++; log('namehook #'+ncalls+' x8='+b+' len='+alen+' heap='+heap+' text="'+txt+'"'); } if(txt && txt.indexOf('exington')>=0){ var s='CyberModMan!'; b.writeUtf8String(s); b.add(0x14).writeU32(s.length); b.add(0x18).writePointer(ptr(0)); log('namehook OVERWROTE "'+txt+'" -> '+s); } }catch(e){ log('namehook onLeave err '+e); } } }); nameHookInstalled=true; log('archivename: Frida interceptor attached at '+naddr+' (open inventory, hover a Lexington)'); }catch(e){ log('archivename err '+e); } return; }   // wall-B: DIRECT Frida interceptor on item name resolver (RED4ext plugin hooks dont fire)
            if(t[0]==='observe'){   // live-register an Observe (works pre-game: settings/main-menu controllers fire here)
                if(t[1]==='off'||t[1]==='clear'){ cmUnobserve(); return; }
                if(t[1]==='list'){ let parts=[]; for(const k in obsByMethod){ for(let i=0;i<obsByMethod[k].length;i++){ const ob=obsByMethod[k][i]; parts.push(ob.className+'.'+ob.methodName+'('+ob.hits+')'); } } log('observe list ['+obsCount+']: '+(parts.join(', ')||'(none)')); return; }
                if(t[1]&&t[2]){ cmObserve(t[1], t[2], null); return; }   // observe <Class> <Method>
                if(t[1]){ cmObserve(null, t[1], null); return; }         // observe <Method>  (matches on any class)
                log('usage: observe <Class> <Method> | observe <Method> | observe list | observe off'); return; }
            if(t[0]==='mkobj'&&t[1]){ try{ const inst=createInstance(t[1]); if(!inst){ log('mkobj '+t[1]+' -> NULL (class unknown or alloc failed)'); return; }
                let dump=''; try{ dump=hexp(inst,0x40); }catch(e){ dump='(read err)'; }
                log('mkobj '+t[1]+' -> '+inst); log('   [0x40]='+dump); }catch(e){ log('mkobj err '+e); } return; }   // create a script object via AllocMemory+ConstructCls
            if(t[0]==='field'&&t[1]&&t[2]){ try{ const f=findProp(t[1],t[2]); if(!f){ log('field '+t[1]+'.'+t[2]+' NOT FOUND'); return; } log('field '+t[1]+'.'+t[2]+' -> offset 0x'+f.off.toString(16)+'  type '+f.typeName); }catch(e){ log('field err '+e); } return; }   // resolve a field offset+type (read-only)
            if(t[0]==='props'&&t[1]){ try{ let cls=clsByName(t[1]); if(!cls){ log('props: class '+t[1]+' UNKNOWN'); return; } let out=[], guard=0;
                while(cls&&!cls.isNull()&&guard++<12){ const pp=cls.add(0x28).readPointer(), n=cls.add(0x30).readU32();
                    for(let i=0;i<n&&out.length<60;i++){ const pr=pp.add(i*8).readPointer(); if(pr.isNull())continue; const nh='0x'+pr.add(0x08).readU64().toString(16); const off=pr.add(0x20).readU32(); let tn='?'; try{tn=nameOf(pr.readPointer());}catch(e){} out.push(nh+'@0x'+off.toString(16)+':'+tn); }
                    cls=cls.add(0x10).readPointer(); }
                log('props '+t[1]+' ['+out.length+']:'); for(let i=0;i<out.length;i+=3) log('   '+out.slice(i,i+3).join('   ')); }catch(e){ log('props err '+e); } return; }   // list class fields (read-only; names are hashes)
            if(t[0]==='mkmods'){ try{ const inst=createInstance('PauseMenuListItemData'); if(!inst){ log('mkmods: create failed'); return; }
                try{ inst.writeUtf8String('Mods'); inst.add(0x14).writeU32(4); inst.add(0x18).writePointer(ptr(0)); }catch(e){ log('  label err '+e); }   // label @0x00 String (inline)
                try{ inst.add(0x20).writeU64(u64(fnv('OnSwitchToSettings'))); }catch(e){ log('  eventName err '+e); }                                  // eventName @0x20 CName
                try{ let ev=resolveEnumByTypeHash('0x'+fnv('PauseMenuAction').toString(16),'OpenSubMenu'); if(ev===null){ log('  action: OpenSubMenu enum not resolved'); } else { inst.add(0x28).writeU32(ev.toNumber()>>>0); log('  action OpenSubMenu = '+ev); } }catch(e){ log('  action err '+e); }   // action @0x28 PauseMenuAction
                let dump=''; try{ dump=hexp(inst,0x40); }catch(e){} log('mkmods -> '+inst+'  (label="Mods" eventName=OnSwitchToSettings)'); log('   [0x40]='+dump); }catch(e){ log('mkmods err '+e); } return; }   // build+fill a Mods menu-item (no PushData yet)
            if(t[0]==='modsbutton'){ if(t[1]==='off'){ cmUnobserve(); log('modsbutton: cleared'); return; }
                const sigOf=function(fn){ try{ const pe=fn.add(0x28).readPointer(),pc=fn.add(0x30).readU32();let p=[];for(let i=0;i<pc;i++){try{p.push(nameOf(pe.add(i*8).readPointer().readPointer()));}catch(e){p.push('?');}}return 'params['+pc+']=['+p.join(', ')+']'; }catch(e){ return 'sigErr'; } };
                try{ const pdc=resolveFunc('inkListController','PushData'); log('modsbutton: inkListController.PushData = '+(pdc?(sigOf(pdc.fn)+' ret='+(pdc.retType.isNull()?'void':nameOf(pdc.retType))):'NOT FOUND')); }catch(e){ log('modsbutton: PushData resolve err '+e); }
                let shown=0;
                cmObserve('gameuiMenuItemListGameController','AddMenuItem', function(ctx){ try{ if(shown>=12) return;
                    const mlc=ctx.add(0x38).readPointer(); let vt=ptr(0); try{ vt=mlc.readPointer(); }catch(e){}
                    if(!vt.isNull()){ shown++; const mm=instType(mlc); const cm=instType(ctx); log('modsbutton: VALID mlc='+mlc+' class='+(mm?nameOf(mm):'?')+'  (ctx class '+(cm?nameOf(cm):'?')+')'); }
                }catch(e){ log('modsbutton cb err '+e); } });
                log('modsbutton: armed (read-only sig capture). Open a menu so AddMenuItem fires; "modsbutton off" clears.'); return; }   // capture PushData contract before we call it
            if(!player){ log('NOT IN GAME yet: '+line); return; }
            if(t[0]==='give'&&t[1]){ doGive(t[1], Math.max(1,parseInt(t[2]||'1')||1)); return; }
            if(t[0]==='money'&&t[1]){ doGive('Items.money', Math.max(1,parseInt(t[1])||1), true); return; }   // currency: always one bulk add
            if(t[0]==='perks'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Primary'); return; }
            if(t[0]==='attrs'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Attribute'); return; }
            if(t[0]==='relic'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Espionage'); return; }
            if(t[0]==='resetperks'){ resetDevelopment('ResetNewPerks','perks'); return; }
            if(t[0]==='resetattrs'){ resetDevelopment('ResetAttributes','attributes'); return; }
            if(t[0]==='godmode'){ doGodmode(t[1]!=='off'); return; }
            if(t[0]==='invis'||t[0]==='invisible'){ doInvisible(t[1]!=='off'); return; }
            if(t[0]==='infammo'||t[0]==='ammo'){ doInfammo(t[1]!=='off'); return; }
            if(t[0]==='time'&&t[1]){ doTime(Math.max(0,Math.min(23,parseInt(t[1])||0)), Math.max(0,Math.min(59,parseInt(t[2]||'0')||0))); return; }
            if(t[0]==='slowmo'){ if(t[1]==='off') doSlowmo(false); else doSlowmo(true, parseFloat(t[1])||0.3); return; }
            if(t[0]==='nopolice'||t[0]==='police'){ doNoPolice(t[1]!=='off'); return; }
            if((t[0]==='removeitem'||t[0]==='remove')&&t[1]){ doRemove(t[1], Math.max(1,parseInt(t[2]||'1')||1)); return; }
            if(t[0]==='heal'){ doHeal(); return; }
            if((t[0]==='setfact'||t[0]==='addfact')&&t[1]){ var fv=(t[2]===undefined?1:parseInt(t[2],10)); if(isNaN(fv))fv=0; doSetFact(t[1], fv); return; }
            if(t[0]==='summon'||t[0]==='car'){ doSummon(); return; }
            if(t[0]==='level'&&t[1]){ doLevel(Math.max(1,parseInt(t[1])||1)); return; }
            if((t[0]==='streetcred'||t[0]==='sc')&&t[1]){ doStreetCred(Math.max(1,Math.min(50,parseInt(t[1])||1))); return; }
            if(t[0]==='teleport'||t[0]==='tp'){ doTeleport(t); return; }
            if(t[0]==='convdump'){ convdump(); return; }
            if(t[0]==='devdump'){ probeFuncs('PlayerDevelopmentSystem',['GetData','GetDevelopmentData','GetDevelopmentDataInternal','GetInstance']);
                probeFuncs('PlayerDevelopmentData',['AddDevelopmentPoints']); return; }
            if(t[0]==='call'&&t[2]){ const cls=t[1],method=t[2],args=t.slice(3); const e=resolveFunc(cls,method); if(!e){ log('method '+cls+'.'+method+' not found'); return; }
                let ctx=instOf(cls); if(args[0]==='@self'){} if(!ctx) ctx=player;
                try{ const r=callFunc(e.fn, ctx, e.retType, args); log('call '+cls+'.'+method+'('+args.join(',')+') -> '+r.readU64()); }catch(ex){ log('call err: '+ex); } return; }
            if(t[0]==='sig'&&t[2]){ const e=resolveFunc(t[1],t[2]); if(!e){ log('sig '+t[1]+'.'+t[2]+' NOT FOUND'); return; }
                const pe=e.fn.add(0x28).readPointer(), pc=e.fn.add(0x30).readU32(); let parts=[];
                for(let i=0;i<pc;i++){ const pr=pe.add(i*8).readPointer(); parts.push(nameOf(pr.readPointer())); }
                log('sig '+t[1]+'.'+t[2]+': params['+pc+']=['+parts.join(', ')+'] ret='+(e.retType.isNull()?'void':nameOf(e.retType))); return; }
            if(t[0]==='findinst'&&t[1]){ const m=clsByName(t[1]); if(!m){ log('findinst: class '+t[1]+' UNKNOWN'); return; }
                const inst=instReg[m.sub(base).add(FV0).toString(16)]; log('findinst '+t[1]+' -> '+(inst?inst:'NONE captured')); return; }
            log('unknown: '+line); }
        setInterval(function(){ try{ const c=readFile(CMD); const s=(c||'').trim();
            if(!s){ lastCmd=''; }                          // file empty -> re-arm so an identical next command fires again
            else if(s!==lastCmd){ lastCmd=s; const cmd=s.replace(/^\d+\t/,''); pendingQ.push(cmd); clearFile(CMD); log('queued: '+cmd); }
            // Q7: Lua Game.* call bridge - a separate synchronous channel (lreq -> lres), queued like a command
            const lq=readFile(LREQ); const ls=(lq||'').trim();
            if(!ls){ lastLReq=''; }
            else if(ls!==lastLReq){ lastLReq=ls; handleLuaCall('lua-call\t'+ls); clearFile(LREQ); } }catch(e){} }, 500);  // perf: was 120ms (8-9 JS wakeups+file reads/sec, forever). 500ms = ~2/sec; console/lua-bridge latency stays imperceptible, and with the overlay off by default there's no producer for CMD anyway.
        // Clean shutdown: the game's static-destructor teardown segfaults with hooks attached (cosmetic,
        // happens AFTER the game has saved + quit). Route exit() -> _exit() to skip that teardown so the
        // process exits cleanly (no macOS crash dialog, exit code 0).
        try{ const eP=resolveExport('exit'), xP=resolveExport('_exit');
            if(eP&&xP){ const _x=new NativeFunction(xP,'void',['int']);
                Interceptor.replace(eP, new NativeCallback(function(c){ _x(c); }, 'void', ['int']));
                log('clean-exit installed'); }
            else log('clean-exit: exit/_exit not resolved'); }catch(e){ log('clean-exit err: '+e); }
        // The real shutdown crash is in the game's own teardown (a stale hook/trampoline call), which runs
        // AFTER the save is flushed but BEFORE exit(). So when Main() returns (game quitting, save done),
        // _exit(0) immediately - we never reach the crashing teardown. (Main is at base+0x31e18 on 2.3.1.)
        try{ const xP2=resolveExport('_exit');
            if(xP2){ const _x2=new NativeFunction(xP2,'void',['int']);
                Interceptor.attach(base.add(0x31e18), { onLeave:function(){ try{ clearFile(CMD); }catch(e){} _x2(0); } });
                log('shutdown-exit hook installed (Main+0x31e18)'); }
            else log('shutdown-exit: _exit unresolved'); }catch(e){ log('shutdown-exit err: '+e); }
        log('==== MINI-CET v3 (universal call + perks/attrs/relic) ready ====');
        Interceptor.attach(execAddr,{
            onEnter:function(args){ depth++; if(busy) return;
                try{ const fn=args[0],ctx=args[1]; if(fn.isNull()||ctx.isNull()) return;
                    if(!fromtd){ const nm='0x'+fn.add(0x08).readU64().toString(16); if(nm==='0x150155547ef75590'){ const rp=fn.add(0x18).readPointer(); fromtd={fn:fn,ctx:ctx,retType:rp.isNull()?ptr(0):rp.readPointer()}; } }
                    const vt=ctx.readPointer(); if(vt.isNull()) return;
                    // Observe dispatch (zero cost when no observers registered). Must run BEFORE the
                    // player/seenVt early-returns below, or observers would fire at most once per vtable.
                    if(obsCount){ const omh='0x'+fn.add(0x10).readU64().toString(16); const olist=obsByMethod[omh];
                        if(olist){ let cmeta=null; try{ cmeta=new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(ctx); }catch(e){}
                            for(let oi=0;oi<olist.length;oi++){ const ob=olist[oi]; if(ob.classHash && (cmeta===null || !classIsA(cmeta, ob.classHash))) continue; obsFire(ob, ctx, args[2], fn); } } }
                    if(playerVt && vt.equals(playerVt)){ player=ctx; addCand(ctx); return; }
                    const vk=vt.toString(); if(seenVt.has(vk)) return; seenVt.add(vk);
                    const fn0=vt.readPointer(); if(fn0.isNull()) return;
                    const meta=new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(ctx);  // GetType -> CClass
                    if(meta.isNull()) return; const fv=meta.sub(base).add(FV0).toString(16); instReg[fv]=ctx;
                    if(nameOf(meta)===PLAYER){ playerVt=vt; player=ctx; addCand(ctx); }
                }catch(e){} },
            onLeave:function(r){ depth--; if(busy) return; if(pendingQ.length&&depth===0){ const cmd=pendingQ.shift(); busy=true; try{ execute(cmd); }catch(e){ log('exec err '+e); } busy=false; } }
        });

        // ---- AUTO-LOAD: apply installed mods on launch, no console needed (NightCity Console increment 4).
        // Queue `tweakload` then `archiveload` into pendingQ so they run on the ENGINE thread (drained by the
        // exec hook above), exactly like the manual commands. Both underlying exports are idempotent +
        // serialized (cybermodman_tweakReload EnsureInitialized, cybermodman_archiveReload compare_exchange),
        // so queueing at several delays to bracket the TweakDB/depot ready window is harmless - the call that
        // lands after readiness is the one that takes effect. Disable by creating /tmp/cp2077_no_autoload.
        try {
            if (readFile('/tmp/cp2077_no_autoload') === null) {
                var alDelays = [6000, 14000, 26000, 45000];
                alDelays.forEach(function (d) {
                    setTimeout(function () {
                        try { pendingQ.push('tweakload'); pendingQ.push('archiveload');
                              log('[AUTOLOAD] queued tweakload+archiveload (+' + d + 'ms)'); }
                        catch (e) { log('[AUTOLOAD] queue err ' + e); }
                    }, d);
                });
                log('[AUTOLOAD] armed - will apply installed mods at ' + alDelays.join('/') + 'ms after launch');
            } else {
                log('[AUTOLOAD] disabled (/tmp/cp2077_no_autoload present)');
            }
        } catch (e) { log('[AUTOLOAD] arm err ' + e); }
    }catch(e){ log('MINI-CET v3 FAILED: '+e); }

// ===== cybermodman cmn loc-hook (re-merged after CET update) =====
var cmnB = getModuleBase();
var CMN_CONFIG = '/Users/ysr/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext/cybermodman_names.json';
var CMN_XL_LOC = '/tmp/cp2077_xl_loc.json';   // ArchiveXL macOS localization handoff (per-mod onscreens -> {fnv32/fnv64-low: text}). Auto-dumped by ArchiveXL on bring-up; served here since the engine LoadTexts merge cannot be caught post-load on macOS.
var CMN_LOG = '/tmp/cybermodman_names.log';
var cmnMap = {};
var cmnHit = {}; // cybermodman: runtime fill hit-counter per LocKey (throttled logging)
var cmnStrCache = {}; // text -> persistent Frida buffer (kept alive; reused)
var cmnBase = null;
var cmnReserve = null;   // NativeFunction(FUN_10002c904): grows a CString to a game-pool heap buffer
var cmnAttached = false;
function cmnLog(s){ try{ var f=new File(CMN_LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{ console.log('[CMN] '+s); }catch(e2){} }
function cmnLoadFile(path, label, verbose){
    var n = 0;
    try {
        var txt = File.readAllText(path);
        if (!txt) { return 0; }
        var obj = JSON.parse(txt);
        for (var k in obj) {
            if (!obj.hasOwnProperty(k)) continue;
            var radix = (k.indexOf('0x')===0 || k.indexOf('0X')===0) ? 16 : 10;
            var kp = parseInt(k, radix);
            if (isNaN(kp)) { cmnLog('  skip non-numeric key "'+k+'"'); continue; }
            var ki = kp >>> 0;
            cmnMap[ki] = String(obj[k]);
            n++;
            if (verbose) cmnLog('  map LocKey '+ki+' (0x'+ki.toString(16)+') -> "'+cmnMap[ki]+'"');
        }
        cmnLog('loaded '+n+' name(s) from '+label);
    } catch (e) { cmnLog(label+' load error: '+e); }
    return n;
}
function cmnLoad(){
    cmnMap = {};
    var n = cmnLoadFile(CMN_CONFIG, 'cybermodman_names.json', true);
    n += cmnLoadFile(CMN_XL_LOC, 'cp2077_xl_loc.json (ArchiveXL)', false);   // mod localization handoff (quiet; can be large)
    cmnLog('total custom name(s): '+n);
    return n;
}
// Write a CString into the engine's output buffer at b. Short strings go inline (proven path).
// Long strings use a persistent buffer + the 0x80000000 'not-owned' flag so the engine reads the
// text but its destructor SKIPS free (verified: dtor frees only when (length>>30)!=2). No allocator
// mismatch, any length safe. (CString: ptr/inline @0x00, capacity @0x10, length+flags @0x14.)
function cmnPutStr(b, s){
    if (s.length < 0x14) {                         // short -> inline (proven)
        b.writeUtf8String(s);
        b.add(0x14).writeU32(s.length);
        b.add(0x18).writePointer(ptr(0));
        return;
    }
    // long -> game-allocated heap CString so the engine both READS (0x40000000) and FREES it safely
    // (FUN_10002c904 allocs from the PoolString pool when allocator@0x18==0; the dtor frees via the
    // same pool). We zero @0x18 first, grow, then write our text into the returned game buffer.
    try {
        if (cmnReserve) {
            b.add(0x18).writePointer(ptr(0));       // default pool allocator
            cmnReserve(b, s.length);                // alloc -> ptr@0x00, capacity@0x10, len|0x40000000
            var p = b.readPointer();
            if (p && !p.isNull()) {
                p.writeUtf8String(s);               // write text into game buffer
                b.add(0x14).writeU32((s.length & 0x3FFFFFFF) | 0x40000000);
                return;
            }
        }
    } catch (e) { try { cmnLog('reserve err: '+e); } catch (_) {} }
    var t = s.substr(0, 19);                        // fallback: inline-truncate (never blank/crash)
    b.writeUtf8String(t);
    b.add(0x14).writeU32(t.length);
    b.add(0x18).writePointer(ptr(0));
}
function cmnInstall(){
    if (cmnAttached) return;
    var cmnB = getModuleBase();
    if (!cmnB) { cmnLog('module cmnB not found; cannot install'); return; }
    cmnBase = cmnB;
    try { cmnReserve = new NativeFunction(cmnB.add(0x2c904), 'void', ['pointer','uint']); } catch (e) { cmnLog('reserve fn err: '+e); }
    var addr = cmnB.add(0x2f6ea14); // FUN_102f6ea14 loc-map lookup: out=x8, key=x1, &found=x3
    try {
        Interceptor.attach(addr, {
            onEnter: function (a) { this.out = this.context.x8; this.k1 = this.context.x1; this.fp = this.context.x3; },
            onLeave: function (r) {
                try {
                    if (!this.k1) return;
                    var name = cmnMap[this.k1.toUInt32() >>> 0];
                    if (name === undefined) return;
                    var __k = this.k1.toUInt32() >>> 0;
                    if (cmnHit[__k] === undefined) cmnHit[__k] = 0;
                    if (cmnHit[__k]++ < 4) cmnLog('HIT key='+__k+' (0x'+__k.toString(16)+') fill="'+String(name).substring(0,48)+'"');
                    var b = this.out; if (!b || b.isNull()) return;
                    cmnPutStr(b, name); // inline (short) or not-owned persistent buffer (long)
                    if (this.fp && !this.fp.isNull()) { try { this.fp.writeU8(1); } catch (e) {} } // force found=1
                } catch (e) {}
            }
        });
        cmnAttached = true;
        cmnLog('interceptor attached at '+addr+' (FUN_102f6ea14)');
    } catch (e) { cmnLog('attach error: '+e); }
}
try { cmnLog('=== cybermodman custom-names init ==='); cmnLoad(); cmnInstall(); } catch (e) { try { console.log('[CMN] init err '+e); } catch (_) {} }

// ============================================================================
// TASK 2 -- installModFolderLoader: register a Mod-scope(4) ArchiveSet for
//   <gamedir>/archive/Mac/mod into the live ResourceDepot at InitializeArchives
//   time, so loose .archive mods get scanned+loaded by the engine's own path.
//
// SAFETY GATE (U4): defaults to DUMP-ONLY. On first run it ONLY raw-reads the
//   depot groups DynArray @depot+0x10 and the first ArchiveSet's bytes
//   [0x00..0x38] and LOGS them to /tmp/cp2077_moddir.log. This PROVES the
//   struct layout (group stride 0x38, basePath@0x08, scope@0x30 [Mod=4]) BEFORE
//   we ever construct/append anything. Flip CP2077_MODDIR_WRITE=true ONLY after
//   the dump confirms the offsets live.
//
// Offset truth (/Users/ysr/cp2077/_ghidra/offsets.json, VERIFIED):
//   InitializeArchives outer = base+0x3ed9578  (hook onLeave of the OUTER, not
//                                                the inner worker 0x3ed96b0)
//   ArchiveSet::Append       = base+0x3edd568
//   per-set enumerator       = base+0x3eda684
//   CString(const char*)ctor = base+0x2cdb8
//   pool CString alloc       = base+0x2c904   (mirror cmnReserve/cmnPutStr)
//   ResourceDepot.groups @0x10 (DynArray {ptr,size,cap}); ArchiveSet stride
//   0x38; ArchiveSet.archives@0x00 (DynArray), basePath@0x08 (CString),
//   scope@0x30 (u32; Mod=4).
//
// FALLBACK NOTE (U1, enumerator arg sig uncertain): if the enumerator at
//   base+0x3eda684 misbehaves live, fall back to a JS glob -- read the newline-
//   separated list of absolute .archive paths from /tmp/cp2077_modlist.txt
//   (written by the overlay's Mods tab, which has POSIX disk access Frida lacks)
//   and feed each path to the per-file loader near base+0x3edb0a4. That path is
//   NOT wired here (DUMP-ONLY ship); this comment records the contract.
// ============================================================================
(function installModFolderLoader(){
    var MODDIR_LOG = '/tmp/cp2077_edafcc.log';
    // U4 SAFETY GATE: DUMP-ONLY by default. Do NOT flip to true until the dump
    // in /tmp/cp2077_moddir.log confirms stride 0x38 / basePath@0x08 / scope@0x30.
    var CP2077_MODDIR_WRITE = true;
    // Relative path of the mod archive folder under the game dir.
    var MOD_REL_PATH = 'archive/Mac/mod';
    var MOD_SCOPE = 4;            // ArchiveSet scope: Mod
    var SET_STRIDE = 0x38;        // ArchiveSet stride within the groups DynArray
    var OFF_GROUPS = 0x10;        // ResourceDepot.groups DynArray {ptr,size,cap}
    var OFF_SET_ARCHIVES = 0x00;  // ArchiveSet.archives (DynArray)
    var OFF_SET_BASEPATH = 0x10;  // ArchiveSet.basePath (CString) -- CONFIRMED via live dump (was wrongly 0x08)
    var OFF_SET_SCOPE = 0x30;     // ArchiveSet.scope (u32) -- CONFIRMED (Content=1,DLC=2,Patch=3,Mod=4)
    // NOTE: write path still needs the enumerator/loader flow RE'd (0x3eda684 takes 4 stack-buffer args,
    // followed by FUN_103edafcc) before CP2077_MODDIR_WRITE can be safely enabled. Layout is pinned; the
    // load-trigger is not. The PROVEN working loose-mod path today: prefixed archives in archive/Mac/content.

    function mlog(s){
        try { var f = new File(MODDIR_LOG, 'a'); f.write(s + '\n'); f.flush(); f.close(); } catch (e) {}
        try { console.log('[MODDIR] ' + s); } catch (e2) {}
    }
    function hexb(p, n){
        try { var b = new Uint8Array(p.readByteArray(n)); var r = ''; for (var i = 0; i < b.length; i++) r += ('0' + b[i].toString(16)).slice(-2) + ' '; return r.trim(); }
        catch (e) { return 'ERR(' + e + ')'; }
    }
    // Read a CString's text without owning it: SSO inline if len<0x14 else heap ptr@0x00.
    function readCStr(cs){
        try {
            var lenFlags = cs.add(0x14).readU32();
            var len = lenFlags & 0x3FFFFFFF;
            if (len < 0x14) return cs.readUtf8String(len < 0 ? 0 : len);
            var p = cs.readPointer();
            if (p.isNull()) return '<null>';
            return p.readUtf8String(len);
        } catch (e) { return '<cstr err ' + e + '>'; }
    }

    var base = null;
    try { base = getModuleBase(); } catch (e) { base = null; }
    if (!base) { mlog('module base not found; mod-folder loader NOT installed'); return; }

    // CString ctor: CString::CString(this, const char*) @ base+0x2cdb8 (zeroes SSO buf + len, interns).
    var fnCStrCtor = null;
    try { fnCStrCtor = new NativeFunction(base.add(0x2cdb8), 'pointer', ['pointer', 'pointer']); } catch (e) { mlog('CString ctor bind err: ' + e); }
    // pool CString grow @ base+0x2c904 (mirror cmnReserve): grows to a game-pool heap buffer.
    var fnPoolReserve = null;
    try { fnPoolReserve = new NativeFunction(base.add(0x2c904), 'void', ['pointer', 'uint']); } catch (e) { mlog('pool reserve bind err: ' + e); }
    // ArchiveSet::Append(groupsDynArray*, ArchiveSet*) @ base+0x3edd568.
    var fnAppend = null;
    try { fnAppend = new NativeFunction(base.add(0x3edd568), 'void', ['pointer', 'pointer']); } catch (e) { mlog('Append bind err: ' + e); }
    // Per-set enumerator (scan+load) @ base+0x3eda684. ABI uncertain (U1) -- called
    // best-effort as (set, &set.archives, 0,0,0); guarded in try/catch.
    var fnEnum = null;
    try { fnEnum = new NativeFunction(base.add(0x3eda684), 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']); } catch (e) { mlog('enum bind err: ' + e); }
    // LoadArchives(depot, set, &dirCString, &outBuffer, &prefixCString, &prefix2CString) @ base+0x3edaae8.
    // Decoded from a live args-probe: x4 = filename prefix ("ep1_"), x5 = prefix base + "\\" ("ep1\\").
    var fnLoadArchives = null;
    try { fnLoadArchives = new NativeFunction(base.add(0x3edaae8), 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer']); } catch (e) { mlog('LoadArchives bind err: ' + e); }

    // Build a red::CString for an absolute path. Prefer the engine ctor (0x2cdb8);
    // for long paths back it with the pool allocator (0x2c904) mirroring cmnPutStr
    // so the engine both READS (0x40000000 flag) and FREES it via the same pool.
    function buildCString(absPath){
        var cs = Memory.alloc(0x20);
        cs.writeU64(0); cs.add(0x08).writeU64(0); cs.add(0x10).writeU64(0); cs.add(0x18).writeU64(0);
        if (absPath.length < 0x14 && fnCStrCtor) {
            try {
                var cstr = Memory.allocUtf8String(absPath);
                fnCStrCtor(cs, cstr);
                return cs;
            } catch (e) { mlog('ctor path err (short): ' + e); }
        }
        // long path: pool-reserve then write text into the returned game buffer (mirror cmnPutStr).
        if (fnPoolReserve) {
            try {
                cs.add(0x18).writePointer(ptr(0));            // default pool allocator
                fnPoolReserve(cs, absPath.length);            // alloc -> ptr@0x00, cap@0x10
                var p = cs.readPointer();
                if (p && !p.isNull()) {
                    p.writeUtf8String(absPath);
                    cs.add(0x14).writeU32((absPath.length & 0x3FFFFFFF) | 0x40000000);
                    return cs;
                }
            } catch (e) { mlog('pool reserve path err: ' + e); }
        }
        // last-ditch fallback: inline-truncate (proves layout without crash).
        try {
            var t = absPath.substr(0, 19);
            cs.writeUtf8String(t);
            cs.add(0x14).writeU32(t.length);
            cs.add(0x18).writePointer(ptr(0));
        } catch (e) {}
        return cs;
    }

    // U4 SAFETY GATE -- raw-read the depot's groups DynArray and the first
    // ArchiveSet [0x00..0x38] and LOG them. NO writes. Proves stride/offsets.
    var dumped = false;
    function dumpDepot(depot){
        if (dumped) return;
        dumped = true;
        try {
            mlog('=== dumpDepot @ ' + depot + ' (DUMP-ONLY safety gate) ===');
            if (!depot || depot.isNull()) { mlog('  depot is null'); return; }
            var groups = depot.add(OFF_GROUPS);             // DynArray {ptr,size,cap}
            var gptr = groups.readPointer();
            var gsize = groups.add(0x08).readU32();
            var gcap = groups.add(0x0C).readU32();
            mlog('  groups@0x10: ptr=' + gptr + ' size=' + gsize + ' cap=' + gcap + ' (stride expect 0x' + SET_STRIDE.toString(16) + ')');
            mlog('  groups raw[0x10]=' + hexb(groups, 0x10));
            if (gptr.isNull() || gsize === 0) { mlog('  no ArchiveSets present yet'); return; }
            // BRUTE-FORCE candidate offsets across ALL sets to PIN basePath + scope exactly.
            // Whichever basePath offset decodes "archive/mac/content|patch|ep1" is the real one;
            // whichever scope offset reads 1/2/3 across the sets is the real scope field.
            var bpCands = [0x08, 0x10, 0x18, 0x20];
            var scCands = [0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c];
            for (var si = 0; si < gsize && si < 4; si++) {
                var s = gptr.add(si * SET_STRIDE);
                mlog('  --- set[' + si + '] @ ' + s + ' bytes=' + hexb(s, SET_STRIDE));
                var arch = s.add(OFF_SET_ARCHIVES);
                mlog('    archives@0x00: ptr=' + arch.readPointer() + ' size=' + arch.add(0x08).readU32());
                for (var bi = 0; bi < bpCands.length; bi++) {
                    var txt = readCStr(s.add(bpCands[bi]));
                    if (txt && txt.length > 2 && txt.indexOf('<') !== 0 && /[a-z\/]/i.test(txt))
                        mlog('    basePath@0x' + bpCands[bi].toString(16) + ' = "' + txt + '"');
                }
                var sc = '    scope candidates: ';
                for (var ci = 0; ci < scCands.length; ci++) { try { sc += '0x' + scCands[ci].toString(16) + '=' + s.add(scCands[ci]).readU32() + ' '; } catch (e) {} }
                mlog(sc);
            }
        } catch (e) { mlog('dumpDepot err: ' + e); }
    }

    // Resolve <gamedir> from the depot rootPath (CString @ depot+0x30 per offsets.json),
    // falling back to the known Steam install path used elsewhere in this file.
    function gameDirFrom(depot){
        try {
            var root = readCStr(depot.add(0x30));
            if (root && root.length > 1 && root.indexOf('<') !== 0) {
                return root.replace(/[\/\\]+$/, '');
            }
        } catch (e) {}
        return '/Users/ysr/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077';
    }

    var didWrite = false;
    function appendModSet(depot){
        if (didWrite) return;
        didWrite = true;
        try {
            var gameDir = gameDirFrom(depot);
            var absPath = gameDir + '/' + MOD_REL_PATH;
            mlog('=== appendModSet: building Mod-scope(4) ArchiveSet for "' + absPath + '" ===');

            // allocate a fresh ArchiveSet (stride 0x38), zeroed.
            var set = Memory.alloc(SET_STRIDE);
            Memory.protect(set, SET_STRIDE, 'rw-');
            for (var i = 0; i < SET_STRIDE; i += 8) set.add(i).writeU64(0);

            // archives@0x00 = empty DynArray (zeroed); basePath@0x08 = CString; scope@0x30 = 4.
            var cs = buildCString(absPath);
            Memory.copy(set.add(OFF_SET_BASEPATH), cs, 0x20);   // copy CString bytes into the set
            set.add(OFF_SET_SCOPE).writeU32(MOD_SCOPE);
            mlog('  set built: basePath="' + readCStr(set.add(OFF_SET_BASEPATH)) + '" scope=' + set.add(OFF_SET_SCOPE).readU32());

            // append to depot.groups DynArray via ArchiveSet::Append(groups, set).
            if (!fnAppend || !fnLoadArchives) { mlog('  fnAppend/fnLoadArchives unavailable -- aborting write'); return; }
            var groups = depot.add(OFF_GROUPS);
            var beforeSize = groups.add(0x08).readU32();
            fnAppend(groups, set);
            var afterSize = groups.add(0x08).readU32();
            mlog('  Append: groups.size ' + beforeSize + ' -> ' + afterSize);
            if (afterSize <= beforeSize) { mlog('  Append did not grow groups -- aborting load'); return; }
            var gptr = groups.readPointer();
            var newSet = gptr.add((afterSize - 1) * SET_STRIDE);
            mlog('  newSet @ ' + newSet + ' basePath="' + readCStr(newSet.add(OFF_SET_BASEPATH)) + '" scope=' + newSet.add(OFF_SET_SCOPE).readU32());

            // LoadArchives(depot, set, &dirCString, &outBuf, &prefixCString, &prefix2CString) per supported prefix.
            // Decoded from the live args-probe (x4="ep1_", x5="ep1\\"). A mod .archive must be NAMED with a
            // recognized prefix to be picked up; we scan for the common ones.
            var prefixes = ['archive_', 'basegame_', 'mod_'];
            for (var pi = 0; pi < prefixes.length; pi++) {
                try {
                    var pfx = prefixes[pi];
                    var pbase = pfx.replace(/_$/, '');                 // "archive"
                    var dirCS = buildCString(absPath);                 // dir to scan (archive/Mac/mod/)  -> x2
                    var outBuf = Memory.alloc(0x80); for (var k = 0; k < 0x80; k += 8) outBuf.add(k).writeU64(0);  // x3 scratch
                    var p1 = buildCString(pfx);                        // "archive_"  -> x4
                    var p2 = buildCString(pbase + '\\');               // "archive\"  -> x5
                    var before = newSet.add(OFF_SET_ARCHIVES).add(0x08).readU32();
                    fnLoadArchives(depot, newSet, dirCS, outBuf, p1, p2);
                    var after = newSet.add(OFF_SET_ARCHIVES).add(0x08).readU32();
                    mlog('  LoadArchives prefix "' + pfx + '": archives.size ' + before + ' -> ' + after);
                } catch (e) { mlog('  LoadArchives("' + prefixes[pi] + '") err: ' + e); }
            }
            var total = newSet.add(OFF_SET_ARCHIVES).add(0x08).readU32();
            mlog('  === DONE: Mod set archives.size=' + total + ' (drop prefixed .archive in ' + absPath + ') ===');
        } catch (e) { mlog('appendModSet err: ' + e); }
    }

    // === NEW (Option A clean write): hook FUN_103edafcc (0x3edafcc) directly.
    //   It loops the depot's scope-config array (base ptr [depot+0x68], count
    //   [depot+0x74], stride 0x140) and per entry runs the ENGINE'S OWN flow:
    //     registrar 0x103449908(name) -> Append 0x103edd568(groups, seed, descriptor)
    //       -> LoadArchives 0x103edaae8(depot, set, &descriptor, outBuf, prefix, path).
    //   Entry layout (Ghidra-decoded): seed@0x80 (first u32 = scope), filename-prefix
    //   CString@0x88 (LoadArchives x4, e.g. "ep1_"), path/subfolder CString@0xa8
    //   (registrar name + LoadArchives x5, e.g. "ep1\\").
    //   STEP 1 (this build, gate=false): DUMP every live entry -> /tmp/cp2077_edafcc.log
    //     so we learn the exact 0x140 layout from real data.
    //   STEP 2 (flip gate after dump confirms): clone a template entry, patch
    //     scope->4 + path->"mod", and RE-INVOKE FUN_103edafcc with a synthetic
    //     1-entry array so the engine itself registers+loads archive/Mac/mod.
    var ENTRY_STRIDE = 0x140;
    var OFF_ARR_PTR  = 0x68;   // depot+0x68 = scope-config array base ptr
    var OFF_ARR_CNT  = 0x74;   // depot+0x74 = array count (u32)
    var OFF_E_SEED   = 0x80;   // entry+0x80 = Append scope-seed (first u32 = scope)
    var OFF_E_PREFIX = 0x88;   // entry+0x88 = filename-prefix CString (LoadArchives x4)
    var OFF_E_PATH   = 0xa8;   // entry+0xa8 = path/subfolder CString (registrar name + LoadArchives x5)
    var fnEdafcc = null;
    try { fnEdafcc = new NativeFunction(base.add(0x3edafcc), 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']); } catch (e) { mlog('edafcc bind err: ' + e); }

    function dumpEntries(depot, x1, arrStart, arrEnd, x4){
        try {
            mlog('=== dumpEntries (FUN_103edafcc live args) ===');
            mlog('  depot=' + depot + '  x1(depot+0x48)=' + x1 + '  x4(outBuf)=' + x4);
            var arrPtr = depot.add(OFF_ARR_PTR).readPointer();
            var cnt = depot.add(OFF_ARR_CNT).readU32();
            var n = arrEnd.sub(arrStart).toInt32() / ENTRY_STRIDE;
            mlog('  depot+0x68 arrPtr=' + arrPtr + '  depot+0x74 count=' + cnt + '  | edafcc x2=' + arrStart + ' x3=' + arrEnd + ' derivedCount=' + n);
            for (var i = 0; i < n && i < 8; i++){
                var e = arrStart.add(i * ENTRY_STRIDE);
                mlog('  --- entry[' + i + '] @ ' + e);
                mlog('    seed@0x80 scope(u32)=' + e.add(OFF_E_SEED).readU32() + '  seedBytes=' + hexb(e.add(OFF_E_SEED), 0x40));
                mlog('    prefix@0x88 = "' + readCStr(e.add(OFF_E_PREFIX)) + '"  bytes=' + hexb(e.add(OFF_E_PREFIX), 0x20));
                mlog('    path@0xa8   = "' + readCStr(e.add(OFF_E_PATH)) + '"  bytes=' + hexb(e.add(OFF_E_PATH), 0x20));
                mlog('    head[0x00..0x80]=' + hexb(e, 0x80));
            }
        } catch (err) { mlog('dumpEntries err: ' + err); }
    }

    // captured live args (for the gated replay); MUST replay in edafcc onLeave so
    // cap.x4 (InitializeArchives's sp+0x8 outBuf) is still a valid live pointer.
    var cap = null;
    // build a proper engine red::CString via the game's own ctor FUN_10002cdb8
    // (handles long paths via the pool + sets alloc@0x18 so copy/destroy are safe).
    function mkCStr(s){
        var cs = Memory.alloc(0x20);
        cs.writeU64(0); cs.add(0x08).writeU64(0); cs.add(0x10).writeU64(0); cs.add(0x18).writeU64(0);
        try { fnCStrCtor(cs, Memory.allocUtf8String(s)); } catch (e) { mlog('mkCStr err: ' + e); }
        return cs;
    }
    // DynArray layout (Ghidra-confirmed via Append/LoadArchives): ptr@0x00, cap@0x08(u32), size@0x0c(u32).
    function replayModScope(){
        try {
            if (!cap) { mlog('  replay: no cap -- abort'); return; }
            if (!fnCStrCtor || !fnLoadArchives) { mlog('  replay: missing ctor/LoadArchives -- abort'); return; }
            // 3-arg Append: FUN_103edd568(groups, &seed, &descriptor) -> newSet (returns x0).
            var fnAppend3 = null;
            try { fnAppend3 = new NativeFunction(base.add(0x3edd568), 'pointer', ['pointer', 'pointer', 'pointer']); }
            catch (e) { mlog('  Append3 bind err: ' + e); return; }

            var gameDir = gameDirFrom(cap.depot);
            var modDir = gameDir + '/archive/mac/mod/';   // lowercase mac (engine convention); FS resolves archive/Mac/mod
            mlog('=== replayModScope (DIRECT, no registrar): Mod scope(4) for "' + modDir + '" ===');

            var desc = mkCStr(modDir);                     // descriptor = scan dir (full path CString)
            mlog('  desc="' + readCStr(desc) + '"');
            var seed = Memory.alloc(8); seed.writeU32(MOD_SCOPE); seed.add(4).writeU32(0);  // Append reads only [seed+0]=scope
            var groups = cap.depot.add(0x10);              // depot.groups DynArray
            var before = groups.add(0x0c).readU32();       // size@0x0c
            var newSet = fnAppend3(groups, seed, desc);
            var after = groups.add(0x0c).readU32();
            mlog('  Append -> newSet=' + newSet + '  groups.size ' + before + ' -> ' + after);
            if (!newSet || newSet.isNull()) { mlog('  Append returned null -- abort'); return; }
            mlog('  newSet.basePath@0x10="' + readCStr(newSet.add(0x10)) + '" scope@0x30=' + newSet.add(0x30).readU32());

            // LoadArchives(depot, set, desc, outBuf=cap.x4[live], prefix, path).
            // glob FUN_103eda360 builds the pattern (prefix + "*.archive"); an EMPTY
            // prefix => "*.archive" => loads EVERY .archive in mod/ (true Windows-mod/
            // parity, any filename). It also auto-globs audio_/lang_ but real loose
            // mods don't use those names, so no dupes in practice.
            var prefixCS = mkCStr('');
            var pathCS = mkCStr('mod\\\\');
            var aBefore = newSet.add(0x0c).readU32();      // set.archives.size@0x0c
            mlog('  LoadArchives(depot, newSet, desc, cap.x4, ""=>*.archive, "mod\\\\")...');
            fnLoadArchives(cap.depot, newSet, desc, cap.x4, prefixCS, pathCS);
            var aAfter = newSet.add(0x0c).readU32();
            mlog('  === DONE: Mod set archives.size ' + aBefore + ' -> ' + aAfter + ' (drop ANY *.archive in ' + modDir + ') ===');
        } catch (err) { mlog('replayModScope err: ' + err); }
    }

    var ranOnce = false;
    try {
        var hookAddr = base.add(0x3edafcc); // per-scope loader (loops depot+0x68 array)
        Interceptor.attach(hookAddr, {
            onEnter: function (args) {
                this.depot = args[0]; this.x1 = args[1]; this.arrStart = args[2]; this.arrEnd = args[3]; this.x4 = args[4];
            },
            onLeave: function (retval) {
                if (ranOnce) return;
                ranOnce = true;
                try {
                    var n = this.arrEnd.sub(this.arrStart).toInt32() / ENTRY_STRIDE;
                    cap = { depot: this.depot, x1: this.x1, arrStart: this.arrStart, arrEnd: this.arrEnd, x4: this.x4, n: n };
                    dumpEntries(this.depot, this.x1, this.arrStart, this.arrEnd, this.x4);
                    if (CP2077_MODDIR_WRITE) {
                        mlog('mode=WRITE: replaying FUN_103edafcc for Mod scope');
                        replayModScope();
                    } else {
                        mlog('mode=DUMP-ONLY: entries dumped. Inspect /tmp/cp2077_edafcc.log, then flip CP2077_MODDIR_WRITE=true.');
                    }
                } catch (e) { mlog('onLeave err: ' + e); }
            }
        });
        mlog('installed: Interceptor @ ' + hookAddr + ' (FUN_103edafcc 0x3edafcc), mode=' + (CP2077_MODDIR_WRITE ? 'WRITE' : 'DUMP-ONLY'));

        // --- LoadArchives (0x3edaae8) ARGS PROBE: learn the real call pattern from the base scopes.
        // LoadArchives(x0, x1=set, x2, x3, x4, x5) -> glob(0x3eda360) + consume(0x3eda488). We log the
        // args + derefs for the first calls (content/ep1/patch) so we can replicate the call for archive/Mac/mod.
        try {
            var laCalls = 0;
            Interceptor.attach(base.add(0x3edaae8), {
                onEnter: function (a) {
                    if (laCalls++ >= 6) return;
                    var c = this.context;
                    function hx(v){ try { return v ? ('0x' + v.toString(16)) : '0'; } catch (e) { return '?'; } }
                    mlog('LoadArchives #' + laCalls + ': x0=' + hx(c.x0) + ' x1=' + hx(c.x1) + ' x2=' + hx(c.x2) + ' x3=' + hx(c.x3) + ' x4=' + hx(c.x4) + ' x5=' + hx(c.x5));
                    try { if (c.x1 && !c.x1.isNull()) mlog('    x1(set).basePath@0x10="' + readCStr(c.x1.add(0x10)) + '" scope@0x30=' + c.x1.add(0x30).readU32()); } catch (e) { mlog('    x1 deref err ' + e); }
                    try { if (c.x2 && !c.x2.isNull()) mlog('    x2 bytes=' + hexb(c.x2, 0x20) + ' asCStr="' + readCStr(c.x2) + '"'); } catch (e) {}
                    try { if (c.x0 && !c.x0.isNull()) mlog('    x0 bytes=' + hexb(c.x0, 0x18)); } catch (e) {}
                    try { if (c.x3 && !c.x3.isNull()) mlog('    x3 bytes=' + hexb(c.x3, 0x20) + ' asCStr="' + readCStr(c.x3) + '"'); } catch (e) {}
                    try { if (c.x4 && !c.x4.isNull()) mlog('    x4 bytes=' + hexb(c.x4, 0x20) + ' asCStr="' + readCStr(c.x4) + '"'); } catch (e) {}
                    try { if (c.x5 && !c.x5.isNull()) mlog('    x5 bytes=' + hexb(c.x5, 0x20) + ' asCStr="' + readCStr(c.x5) + '"'); } catch (e) {}
                    // x3 is a stack ptr (caller scratch); x4/x5 heap (context). Knowing these = replication-ready.
                }
            });
            mlog('LoadArchives args-probe attached @ ' + base.add(0x3edaae8) + ' (0x3edaae8)');
        } catch (e) { mlog('LoadArchives probe err: ' + e); }
    } catch (e) { mlog('install FAILED: ' + e); }
})();

// ===========================================================================
// installFactoryIndex (Q-clothing): inject ArchiveXL custom factory CSVs into
// the engine factory index via FRIDA (ArchiveXL's own HookAfter is dead on macOS).
// Bring-up build: read-only instrumentation (markers, JS<->engine hash xcheck,
// CreateEntryMap job-data dump, depot probe) + a try/catch'd piggyback inject.
// Renders LITERAL-appearance items only; '!'-dynamic appearances need a
// DynamicAppearance port next. Addresses are file-offsets; runtime = base+off.
// ===========================================================================
(function installFactoryIndex(){
    // M1b: DISABLED. ArchiveXL's native FactoryIndexExtension now owns the LoadFactoryAsync (0xcc0710)
    // hook via the gum-backed RED4ext Attach. Running this IIFE too would double-patch the same prologue
    // with a second gum instance. installFactoryReseal (0xcc0bec) below STAYS active for the +0x68 race.
    return;
    var base; try { base = getModuleBase(); } catch (e) { base = null; }
    if (!base) return;
    var LOG = '/tmp/cp2077_factoryindex.log';
    function flog(s){ try{ var f=new File(LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{ console.log('[FACTORYIDX] '+s); }catch(e){} }
    try { var f0=new File(LOG,'w'); f0.write('=== installFactoryIndex bring-up ===\n'); f0.close(); } catch(e){}

    // engine-exact ResourcePath hash: FNV1a64 over a sanitized path (strip one leading quote, strip a leading
    // separator run, collapse separator runs to a single '\\', '/'->'\\', ASCII-lowercase, 199-char cap, SIGNED bytes).
    function fnv1a64(s){ var h=BigInt('0xCBF29CE484222325'), P=BigInt('0x100000001b3'), M=(BigInt(1)<<BigInt(64))-BigInt(1);
        for(var i=0;i<s.length;i++){ var b=s.charCodeAt(i)&0xff; if(b>=0x80)b-=256; h^=(BigInt(b)&M); h=(h*P)&M; } return h; }
    function sanitize(p){ if(!p) return ''; var MAX=199,o='',i=0;
        if(p[0]==='"'||p[0]==="'") i++;
        while(i<p.length && (p[i]==='/'||p[i]==='\\')) i++;
        while(i<p.length && p[i]!=='"' && p[i]!=="'"){ var c=p[i];
            if(c==='/'||c==='\\'){ o+='\\'; i++; while(i<p.length && (p[i]==='/'||p[i]==='\\')) i++; }
            else { o+=(c>='A'&&c<='Z')?c.toLowerCase():c; i++; }
            if(o.length===MAX) break; }
        return o; }
    function pathHashHex(p){ var s=sanitize(p); return s.length ? fnv1a64(s).toString(16) : null; }

    var MARK_VEH = pathHashHex('base\\gameplay\\factories\\vehicles\\vehicles.csv');
    var MARK_MAS = pathHashHex('base\\gameplay\\factories.csv');
    flog('markers: vehicles=0x'+MARK_VEH+' master=0x'+MARK_MAS+' (expect f94faab4ff97393a / 6c13dcf96a5bfef4)');
    var MARK_VEH_P = ptr('0x'+MARK_VEH), MARK_MAS_P = ptr('0x'+MARK_MAS);

    // custom factory CSV paths (the Mods tab writes these, one per line; here read from /tmp for bring-up)
    var customs=[];
    try { var t=File.readAllText('/tmp/cp2077_xl_factories.txt'); if(t){ t.split('\n').forEach(function(line){ line=line.trim(); if(!line) return;
        var h=pathHashHex(line); if(!h) return; customs.push({ path:line, hash:h, p:ptr('0x'+h) }); }); } } catch(e){ flog('read xl list err '+e); }
    flog('collected '+customs.length+' custom factory path(s)');
    customs.forEach(function(c){ flog('  custom "'+c.path+'" -> 0x'+c.hash); });

    var fnLoad=null, fnRP=null, fnDepot=null;
    try { fnLoad  = new NativeFunction(base.add(0xcc0710), 'void',    ['pointer','uint64','pointer']); } catch(e){ flog('fnLoad ctor err '+e); }
    try { fnRP    = new NativeFunction(base.add(0x21c90a4),'uint64',  ['pointer','uint32']); } catch(e){ flog('fnRP ctor err '+e); }
    try { fnDepot = new NativeFunction(base.add(0x21c4d44),'pointer', ['uint64']); } catch(e){ flog('fnDepot ctor err '+e); }

    // cross-check our JS hash against the engine's own ResourcePath::Create (a MISMATCH = stop, sanitize is wrong)
    if (fnRP) customs.forEach(function(c){ try{ var cs=Memory.allocUtf8String(c.path); var eng=fnRP(cs, c.path.length);
        flog('  XCHECK "'+c.path+'" js=0x'+c.hash+' eng=0x'+eng.toString(16)+(eng.toString(16)===c.hash?' OK':' *** MISMATCH ***')); }catch(e){ flog('  XCHECK err '+e); } });

    // step C: read-only dump of the engine's OWN CreateEntryMap job-data (so the own-batch seal can be built right later)
    var dumpedMap=false;
    try { Interceptor.attach(base.add(0xcc1434), { onEnter:function(args){ if(dumpedMap) return; dumpedMap=true;
        try{ flog('CreateEntryMap jobData='+args[0]+'\n'+hexdump(args[0],{length:0x48,header:false})); }catch(e){ flog('map dump err '+e); } } });
        flog('installed CreateEntryMap probe @ '+base.add(0xcc1434)); } catch(e){ flog('attach map err '+e); }

    // hook LoadFactoryAsync: log the factory pass + piggyback-inject customs on the marker row (try/catch'd = Frida-safe)
    var injected=false, sawVeh=false, nLFA=0;
    try { Interceptor.attach(base.add(0xcc0710), { onEnter:function(args){ try{
        var aIndex=args[0], aPath=args[1], aCtx=args[2]; nLFA++;
        if(nLFA<=48) flog('LFA #'+nLFA+' aPath='+aPath+' aIndex='+aIndex+' aCtx='+aCtx);
        var isVeh=aPath.equals(MARK_VEH_P), isMas=aPath.equals(MARK_MAS_P);
        if(isVeh) sawVeh=true;
        if((isVeh || (isMas && !sawVeh)) && !injected){ injected=true;
            flog('=== marker hit ('+(isVeh?'vehicles':'master')+') -> piggyback inject '+customs.length+' (aIndex='+aIndex+' aCtx='+aCtx+') ===');
            customs.forEach(function(c){
                try{ if(fnDepot){ var dh=fnDepot(uint64('0x'+c.hash)); flog('  depot "'+c.path+'" -> '+(dh.isNull()?'ABSENT (archive/CSV not loaded)':dh)); } }catch(e){ flog('  depot probe err '+e); }
                try{ fnLoad(aIndex, uint64('0x'+c.hash), aCtx); flog('  LoadFactoryAsync ok 0x'+c.hash); }catch(e){ flog('  LoadFactoryAsync FAIL "'+c.path+'": '+e); } });
        }
    }catch(e){ flog('LFA onEnter err '+e); } } });
    flog('installed LoadFactoryAsync hook @ '+base.add(0xcc0710)); } catch(e){ flog('attach LFA err '+e); }
})();

// installFactoryReseal (THE FIX): our injected ArchiveXL factory rows land in the raw row array
// (factory+0xa0) but the engine's one-shot CreateEntryMap already sealed the queryable HashMap
// (factory+0x68) before our async LoadFactoryAsync appended them -> the equip-time query
// FUN_100cc0bec(factory, entityNameCName) returns 0 -> entity never loads -> invisible. Fix: hook
// that query; when OUR entityName is asked for but missing from +0x68, find our row in +0xa0 and
// insert it (CreateEntryMap's own per-row inserter FUN_10096c938) BEFORE the original body runs, so
// the first equip resolves. Operates on x0 = the exact factory the equip path uses (fixes both
// seal-ordering and wrong-instance modes). Addresses Ghidra-verified on Steam 2.3.1 arm64.
// THE FIX is a RETURN-OVERRIDE: our injected factory rows never landed in the LIVE equip factory's
// +0x68 index (async CreateEntryMap sealed before our async ParseFile appended; the equip factory ptr
// also differs from the boot aIndex). The engine's equip-time resolver FUN_100cc0bec(factory, CName)
// (file off 0xcc0bec) returns the _root.ent ResourcePath = **(rowPtr+0x18), or 0 if the CName isn't
// indexed. Ghidra-proven (workflow wf_d4f7a8f6): the entityName query's result is dead, but the SECOND
// (appearance) query through this SAME function drives the appearance-resource load (req+0x58/req+0x60);
// our item's entityName == appearanceName == "melgardens_swim_string_top_", so both calls use the same
// CName. So: when FUN_100cc0bec is asked for one of our CNames and returns 0 (not in the live index),
// replace the return with our _root.ent ResourcePath -> the engine loads the entity -> builds the garment.
// Both melgardens top_ and bottom_ map to the SAME _root.ent (melgardens_swim_string_root.ent).
(function installFactoryReseal(){
    var LOG='/tmp/cp2077_factoryindex.log';
    function rlog(s){ try{ var f=new File(LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{console.log('[FXRESEAL] '+s);}catch(e){} }
    var base; try{base=getModuleBase();}catch(e){base=null;}
    if(!base){ rlog('reseal: no base'); return; }

    // GENERALIZED (any clothing mod): build the watched entityName->root.ent set from the deployed
    // config `/tmp/cp2077_xl_items.txt` (one "entityName<TAB>rootEntPath" per line, written by
    // `melpack factories`). Each entry's CName = fnv1a64(entityName) and its _root.ent ResourcePath =
    // fnv1a64(sanitize(path)). These two hashers are engine-exact (the disabled installFactoryIndex
    // XCHECK'd them against the engine's own ResourcePath::Create). BigInt is available in this runtime.
    function fnv1a64(s){ var h=BigInt('0xCBF29CE484222325'), P=BigInt('0x100000001b3'), M=(BigInt(1)<<BigInt(64))-BigInt(1);
        for(var i=0;i<s.length;i++){ var b=s.charCodeAt(i)&0xff; if(b>=0x80)b-=256; h^=(BigInt(b)&M); h=(h*P)&M; } return h; }
    function sanitize(p){ if(!p) return ''; var MAX=199,o='',i=0;
        if(p[0]==='"'||p[0]==="'") i++;
        while(i<p.length && (p[i]==='/'||p[i]==='\\')) i++;
        while(i<p.length && p[i]!=='"' && p[i]!=="'"){ var c=p[i];
            if(c==='/'||c==='\\'){ o+='\\'; i++; while(i<p.length && (p[i]==='/'||p[i]==='\\')) i++; }
            else { o+=(c>='A'&&c<='Z')?c.toLowerCase():c; i++; }
            if(o.length===MAX) break; }
        return o; }
    function hx(big){ return '0x'+big.toString(16); }   // matches NativePointer.toString() (lowercase, no leading zero)

    // ENTRIES: cnHex -> { name, resHex }. cnHex matches a[1].toString() at the cc0bec call site.
    var ENTRIES={}, ncfg=0;
    try { var t=File.readAllText('/tmp/cp2077_xl_items.txt');
        if(t){ t.split('\n').forEach(function(line){ line=line.replace(/\r$/,'').trim(); if(!line||line[0]==='#') return;
            var parts=line.split('\t'); if(parts.length<2) return;
            var name=parts[0].trim(), path=parts[1].trim(); if(!name||!path) return;
            ENTRIES[hx(fnv1a64(name))]={ name:name, resHex:hx(fnv1a64(sanitize(path))) }; ncfg++; }); }
    } catch(e){ rlog('read items cfg err '+e); }
    if(ncfg===0){
        // legacy fallback (no cfg deployed): the bikini top_/bottom_ -> melgardens_swim_string_root.ent,
        // so M2 v1 keeps rendering exactly as before.
        ENTRIES['0xa5f426a776aa7ff']={ name:'melgardens_swim_string_top_', resHex:'0xe1d11df4d38d1d94' };
        ENTRIES['0xc86606f3c24e7fe9']={ name:'melgardens_swim_string_bottom_', resHex:'0xe1d11df4d38d1d94' };
        rlog('no items cfg -> legacy bikini fallback');
    } else { rlog('loaded '+ncfg+' factory item(s) from /tmp/cp2077_xl_items.txt'); }
    Object.keys(ENTRIES).forEach(function(cn){ rlog('  ENTRY '+ENTRIES[cn].name+' cn='+cn+' -> root.ent '+ENTRIES[cn].resHex); });

    // ROBUST FIX: actually INSERT a synthesized row into the live equip factory's +0x68 (so EVERY
    // consumer resolves, not just FUN_100cc0bec). Row {+0=CName, +0x18->token(_root.ent path)}; the
    // engine's own per-row inserter FUN_10096c938(scratch, factory+0x68, rowPtr, &rowPtr) links it in.
    // onLeave override remains as a belt-and-suspenders fallback (per-entry _root.ent ResourcePath).
    var insert=null;
    try{ insert=new NativeFunction(base.add(0x96c938),'void',['pointer','pointer','pointer','pointer']); }catch(e){ rlog('insert NF err '+e); }
    var scratch=Memory.alloc(64), rows={};
    Object.keys(ENTRIES).forEach(function(cn){
        var e=ENTRIES[cn];
        var tok=Memory.alloc(8); tok.writeU64(uint64(e.resHex));
        var row=Memory.alloc(0x20);
        for(var i=0;i<0x20;i+=8) row.add(i).writeU64(uint64(0));
        row.writeU64(uint64(cn)); row.add(0x18).writePointer(tok);
        var rv=Memory.alloc(8); rv.writePointer(row);
        rows[cn]={row:row, rv:rv, resPtr:ptr(e.resHex)};
    });
    var inserted={}, ovLog=0, missLog=0, missSeen={};
    try{
        Interceptor.attach(base.add(0xcc0bec), {
            onEnter:function(a){ this.cn=a[1].toString(); this.fac=a[0];
                try{ if(ENTRIES[this.cn] && insert){ var k=this.fac.toString()+':'+this.cn; if(!inserted[k]){ inserted[k]=1; var rr=rows[this.cn]; insert(scratch, this.fac.add(0x68), rr.row, rr.rv); rlog('INSERT '+ENTRIES[this.cn].name+' row -> +0x68 of fac='+this.fac); } } }catch(e){ rlog('insert err '+e); }
            },
            onLeave:function(r){
                try{
                    if(ENTRIES[this.cn]){
                        if(r.isNull()){ r.replace(rows[this.cn].resPtr); if(ovLog<12){ ovLog++; rlog('OVERRIDE(fallback) cc0bec: '+ENTRIES[this.cn].name+' -> _root.ent'); } }
                        else if(ovLog<12){ ovLog++; rlog('*** cc0bec '+ENTRIES[this.cn].name+' RESOLVED -> '+r+' (insert worked) ***'); }
                    } else if(r.isNull() && missLog<40 && !missSeen[this.cn]){ missSeen[this.cn]=1; missLog++; rlog('  (cc0bec miss) x1='+this.cn); }
                }catch(e){ rlog('override err '+e); }
            }
        });
        rlog('factory insert+override hook @ base+0xcc0bec watch='+Object.keys(ENTRIES).join(','));
    }catch(e){ rlog('attach err '+e); }
})();

// installMeshRedirect (gate 3, the @dynamic garment mesh-load fix): an ArchiveXL @dynamic garment component stores
// a DYNAMIC mesh path template, e.g. "*base\nd_base\mesh\nd_top_mila_{gender}_{body}.mesh". On macOS the ArchiveXL
// C++ expansion can't fire (the engine garment ABIs/structs differ from the Windows SDK at every hook we tried),
// so the engine loads the RAW template string -> ResourceToken fails -> null mesh -> GarmentAssembler crash. FIX
// (register-level, upstream of every ABI wall, the FXRESEAL pattern for meshes): the engine resource-token cache
// lookup FUN_1021b4d58 takes the ResourcePath hash as a PLAIN u64 in x1 BEFORE any token binding; swap the dynamic
// mesh-path hash -> the expanded LITERAL hash there, so the engine streams the real mesh. Both hashes are computed
// with the engine's own ResourcePath::Create (0x21c90a4) from /tmp/cp2077_xl_meshalias.txt ("<template>\t<expanded>"
// per @dynamic mesh, produced offline by `archdump | _tools/mkmeshalias.py`). ABI-free, general for any dynamic mod.
(function installMeshRedirect(){
    var LOG='/tmp/cp2077_factoryindex.log';
    function mlog(s){ try{ var f=new File(LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{console.log('[MESHRDR] '+s);}catch(e){} }
    var base; try{base=getModuleBase();}catch(e){base=null;}
    if(!base){ mlog('no base'); return; }

    var fnRP=null, fnDepot=null;
    try{ fnRP=new NativeFunction(base.add(0x21c90a4),'uint64',['pointer','uint32']); }catch(e){ mlog('fnRP ctor err '+e); }
    try{ fnDepot=new NativeFunction(base.add(0x21c4d44),'pointer',['uint64']); }catch(e){ mlog('fnDepot ctor err '+e); }
    if(!fnRP){ mlog('no fnRP - abort'); return; }
    function hx(u){ return '0x'+u.toString(16); }   // matches NativePointer.toString() (lowercase, no leading zero)

    // ALIAS: dynHashHex -> litPtr. Create does NOT strip '*','{','}' (only quotes/slashes) -> dynHash is stable.
    var ALIAS={}, n=0;
    try{
        var t=File.readAllText('/tmp/cp2077_xl_meshalias.txt');
        if(t) t.split('\n').forEach(function(line){
            line=line.replace(/\r$/,'').trim(); if(!line||line[0]==='#') return;
            var parts=line.split('\t'); if(parts.length<2) return;
            var tmpl=parts[0].trim(), exp=parts[1].trim(); if(!tmpl||!exp) return;
            var dyn=fnRP(Memory.allocUtf8String(tmpl), tmpl.length);
            var lit=fnRP(Memory.allocUtf8String(exp), exp.length);
            var dynHex=hx(dyn), litHex=hx(lit);
            var present=true;
            try{ if(fnDepot){ present=!fnDepot(lit).isNull(); } }catch(e){}
            if(!present){ mlog('SKIP "'+exp+'" '+litHex+' ABSENT in depot (literal mesh not in a loaded archive?)'); return; }
            ALIAS[dynHex]=ptr(litHex); n++;
            mlog('alias "'+tmpl+'" '+dynHex+' -> "'+exp+'" '+litHex+' (depot: present)');
        });
    }catch(e){ mlog('read alias err '+e); }
    if(n===0){ mlog('no aliases - redirect not installed'); return; }

    // Swap x1 (ResourcePath hash) at the resource-token cache lookup, before token binding.
    var swaps=0;
    try{
        Interceptor.attach(base.add(0x21b4d58), { onEnter:function(a){
            try{ var lit=ALIAS[a[1].toString()]; if(lit){ if(swaps<25){ swaps++; mlog('SWAP #'+swaps+' '+a[1].toString()+' -> '+lit); } a[1]=lit; } }catch(e){}
        }});
        mlog('installed mesh redirect @ base+0x21b4d58 ('+n+' alias(es))');
    }catch(e){ mlog('attach redirect err '+e); }
})();

// ===== W^X keystone: live trampoline-page fix + diagnostic =====
// The @dynamic garment path crashes when an ArchiveXL HookAfter (OnResolveSuffixes / OnLoadMaterials)
// calls the ORIGINAL through a frida-gum 'original' trampoline: a red engine WORKER thread executes it
// and hits EXC_BAD_ACCESS/KERN_PROTECTION_FAILURE because that specific trampoline page lacks 'x'
// (the entry trampoline on the same thread runs fine -> it is per-PAGE, not per-thread). We catch the
// access-violation, make the faulting page executable, and RESUME. If Memory.protect can flip it, that
// IS the macOS-27 W^X fix (no RED4ext rebuild). The 'tried' guard prevents an infinite re-fault loop.
(function installWXFix(){
    var FLOG='/tmp/cp2077_fault.log';
    function flog(s){ try{var f=new File(FLOG,'a');f.write(s+'\n');f.flush();f.close();}catch(e){} try{console.log('[WXFIX] '+s);}catch(e){} }
    try{var f0=new File(FLOG,'w');f0.write('=== W^X fault handler armed ===\n');f0.close();}catch(e){}
    var tried={}, fixed=0, logged=0;
    try{
        function hexAt(a,n){ try{var b=new Uint8Array(Memory.readByteArray(a,n||16)); return Array.prototype.map.call(b,function(x){return ('0'+x.toString(16)).slice(-2);}).join(' ');}catch(e){return '<rd '+e+'>';} }
        function disAt(a){ try{return Instruction.parse(a).toString();}catch(e){return '<dis '+e+'>';} }
        Process.setExceptionHandler(function(d){
            try{
                var fa=d.address, pc=(d.context?d.context.pc:null);
                // SIGILL: the page is executable but the bytes are not a valid instruction. Dump them so we
                // can tell incomplete-trampoline (zeros/garbage) from stale-icache (valid-looking insn).
                if(d.type==='illegal-instruction'){
                    if(logged<24){ logged++; flog('SIGILL pc='+pc+' addr='+fa+' bytes=['+hexAt(fa)+'] insn='+disAt(fa)); }
                    return false;
                }
                if(d.type!=='access-violation'){ if(logged<24){logged++; flog('EXC type='+d.type+' addr='+fa);} return false; }
                var r=null; try{ r=Process.findRangeByAddress(fa); }catch(e){}
                var key = r ? r.base.toString() : fa.toString();
                tried[key]=(tried[key]||0)+1;
                var prot = r ? r.protection : '<no-range>';
                // LOG-ONLY: do NOT patch/resume. The earlier auto-fix-and-resume turned a single clean fault
                // into a runaway cascade through rw- data pages (and could mask whether a gum change actually
                // worked). Just record the fault and let the process crash/handle normally (return false).
                if(logged<24){ logged++; flog('AV #'+logged+' pc='+pc+' addr='+fa+' range='+(r?(r.base+' sz='+r.size+' prot='+prot):'<none>')+' (LOG-ONLY, not resuming)'); }
                return false;
            }catch(e){ try{flog('handler err '+e);}catch(_){}; return false; }
        });
        flog('exception handler installed (Process.setExceptionHandler)');
    }catch(e){ flog('install err '+e); }
})();

// installAppearanceProbe (Track A diagnostic): read-only probes to pinpoint WHERE custom-clothing
// appearance resolution breaks. Hooks EntityTemplate::FindAppearance (does our literal appearance
// resolve to a template entry?) + ScheduleAppearanceBuildingJobs (did the engine start building the
// garment = appearance resolved end-to-end?). Filtered to our 3 watched CNames + a short calibration.
// When RED4ext's GarmentExtension owns the appearance/garment functions (Garment gate + manual inline
// hooks), the gadget must NOT also hook them: its Frida redirect overwrites the prologue, so RED4ext's
// manual hook reads a branch (PC-relative) and falls back to the broken gum path. false = RED4ext owns
// 0xcb12bc / 0x3710004 / 0xae6660; the gadget skips them.
var CET_OWNS_GARMENT = true;   // true = gadget owns the appearance path (bikini literal force works).
                               // ONLY false for the @dynamic Garment-gate experiment (RED4ext manual hooks own it then).
// Ownership is launch-flag driven so we never have to hand-edit/redeploy this file per mode: if the flag
// file /tmp/cp2077_red4ext_owns_garment exists (created by launch_red4ext_dynamic.sh, removed by the
// normal launch_red4ext.sh), RED4ext owns the Garment fns and the gadget steps aside. Default stays true
// (the bikini literal path) when the flag is absent. readAllText throws if the file is missing -> stays true.
try { File.readAllText('/tmp/cp2077_red4ext_owns_garment'); CET_OWNS_GARMENT = false; } catch(e) {}
try { console.log('[GARMENT-OWNER] ' + (CET_OWNS_GARMENT ? 'CET gadget (bikini literal)' : 'RED4ext manual hooks (@dynamic)')); } catch(e) {}
(function installAppearanceProbe(){
    if(!CET_OWNS_GARMENT){ try{console.log('[APPRPROBE] disabled (RED4ext owns the appearance path)');}catch(e){} return; }
    var LOG='/tmp/cp2077_appearance.log';
    function alog(s){ try{var f=new File(LOG,'a');f.write(s+'\n');f.flush();f.close();}catch(e){} try{console.log('[APPRPROBE] '+s);}catch(e){} }
    try{var f0=new File(LOG,'w');f0.write('=== appearance probe (Track A) ===\n');f0.close();}catch(e){}
    var base; try{base=getModuleBase();}catch(e){base=null;}
    if(!base){ alog('no module base; abort'); return; }
    // watched CNames (FNV1a64 of the raw string). NativePointer.toString() drops the leading zero.
    var WATCH={ '0xa5f426a776aa7ff':'melgardens_swim_string_top_',
                '0x4b5dd0abbc6fc1e4':'black',
                '0xc86606f3c24e7fe9':'melgardens_swim_string_bottom_' };
    // our entity's appearance-entry CNames (to recognize OUR _root.ent template when it's queried).
    // Seeded with the bikini defaults, then EXTENDED from /tmp/cp2077_xl_appearances.txt (the ArchiveXL
    // appearance handoff: one "<cnameHex>\t<name>" per mod root.ent appearance entry) so ANY mod's
    // templates are recognized + force-resolved, not just the bikini. Same format the engine reports.
    var OURS={ '0xa5f426a776aa7ff':1, '0xc86606f3c24e7fe9':1 };
    var OURS_NAME={ '0xa5f426a776aa7ff':'melgardens_swim_string_top_', '0xc86606f3c24e7fe9':'melgardens_swim_string_bottom_' };
    try{
        var atxt=File.readAllText('/tmp/cp2077_xl_appearances.txt');
        if(atxt){ atxt.split('\n').forEach(function(ln){ ln=(ln||'').trim(); if(!ln||ln[0]==='#') return;
            var parts=ln.split('\t'); var k=(parts[0]||'').trim().toLowerCase(); if(k.indexOf('0x')!==0) return;
            var norm='0x'+BigInt(k).toString(16);   // strip leading zeros -> matches the engine's reported CName
            OURS[norm]=1; OURS_NAME[norm]=(parts[1]||'').trim(); }); }
        alog('appearance handoff: '+Object.keys(OURS).length+' mod appearance entr(ies) recognized');
    }catch(e){ alog('appearances file load err '+e); }
    var FORCE_TOP = ptr('0xa5f426a776aa7ff');   // bikini bare top (preferred bikini force; no regression)
    // cheap detector: ONLY scan small templates (our _root.ent has 2 entries; NPC/player templates have many),
    // so this stays light even during city load. Returns entry hashes if this is OUR template, else null.
    function templateIsOurs(tmpl){
        try{
            var sz=tmpl.add(0x5c).readU32();
            if(sz===0 || sz>12) return null;                 // skip heavy templates entirely
            var arr=tmpl.add(0x50).readPointer();
            if(arr.isNull()) return null;
            var hs=[], ours=false;
            for(var i=0;i<sz;i++){ var nh=arr.add(i*0x18).readU64().toString(); hs.push(nh); if(OURS[nh]) ours=true; }
            return ours ? hs : null;
        }catch(e){ return null; }
    }
    var calib=0, ourSeen=0;
    try{
        if(CET_OWNS_GARMENT) Interceptor.attach(base.add(0xcb12bc), {
            onEnter:function(a){ this.tmpl=a[0]; var h=a[1].toString(); this.h=h; this.w=WATCH[h];
                if(this.w) alog('FindAppearance REQUEST name='+this.w+' ('+h+')');
                else if(calib<6){ calib++; alog('  (calib) x1='+h); }
                // FIX #2 + confirm: if this is OUR _root.ent template, log the searched name and FORCE the
                // bare top appearance so a &Female/&FPP-suffixed search still resolves.
                try{ var hs=templateIsOurs(this.tmpl);
                    if(hs){
                        // force x1 to the bare mod appearance entry: prefer the bikini top (no regression),
                        // else the first of THIS template's own entries that is a known mod appearance.
                        var ft = OURS['0xa5f426a776aa7ff'] && hs.indexOf('0xa5f426a776aa7ff')>=0 ? '0xa5f426a776aa7ff' : null;
                        if(!ft){ for(var fi=0;fi<hs.length;fi++){ if(OURS[hs[fi]]){ ft=hs[fi]; break; } } }
                        if(ft){ if(ourSeen<25){ ourSeen++; alog('*** OUR _root.ent QUERIED: searched='+h+' entries=['+hs.join(',')+'] -> FORCE x1='+ft+' ('+(OURS_NAME[ft]||'?')+') ***'); }
                            this.context.x1 = ptr(ft); }
                    }
                }catch(e){}
            },
            onLeave:function(r){ if(this.w) alog('FindAppearance RESULT '+this.w+' -> '+(r.isNull()?'NULL':r)); }
        });
        alog('FindAppearance hook @ base+0xcb12bc OK (detect OUR template + force bare name)');
    }catch(e){ alog('FindAppearance hook err '+e); }
    var schedN=0;
    try{
        Interceptor.attach(base.add(0xca0adc), {
            onEnter:function(a){ schedN++; if(schedN<=40) alog('ScheduleAppearanceBuildingJobs FIRED #'+schedN+' x0='+a[0]); }
        });
        alog('ScheduleAppearanceBuildingJobs hook @ base+0xca0adc OK');
    }catch(e){ alog('Schedule hook err '+e); }
    // AppearanceResource::FindAppearanceDefinition FUN_100ad7048(out, appRes, CName, u32, u8) — the .app
    // appearance resolver (param_3 = appearance CName). If THIS fires with our appearance name, the entity
    // loaded + reached the .app (problem is downstream at mesh/garment); if it never fires, the entity
    // never reached .app resolution (stall is at entity-load).
    var APPWATCH={ '0xa5f426a776aa7ff':'melgardens_swim_string_top_', '0xc86606f3c24e7fe9':'melgardens_swim_string_bottom_', '0x4b5dd0abbc6fc1e4':'black' };
    var fadN=0;
    try{
        Interceptor.attach(base.add(0xad7048), {
            onEnter:function(a){ var h=a[2].toString(); if(APPWATCH[h]){ alog('*** FindAppearanceDefinition REQUEST appCName='+APPWATCH[h]+' ('+h+') appRes='+a[1]+' ***'); }
                else if(fadN<10){ fadN++; alog('  (FAD calib) appCName='+h); } },
            onLeave:function(r){ if(this.w){} }
        });
        alog('FindAppearanceDefinition hook @ base+0xad7048 OK');
    }catch(e){ alog('FAD hook err '+e); }
})();

// installStreamProbe (blocker #1 diagnosis): does our _root.ent (and the .app/_top.ent/mesh chain) actually
// STREAM from the depot, and does the ItemFactoryRequest state machine advance past state 2 (the token-wait that
// "keeps loading forever")? Resource-cache lookup FUN_1021b4d58(x0, x1=ResourcePath) @0x21b4d58; request state
// machine FUN_1036e783c(x0=req) @0x36e783c, state at req+0x108 (stuck at 2 == loading forever, 3 == FindAppearance runs).
(function installStreamProbe(){
    if(!CET_OWNS_GARMENT){ try{console.log('[STREAM] disabled (RED4ext owns the appearance path)');}catch(e){} return; }
    var LOG='/tmp/cp2077_stream.log';
    function slog(s){ try{var f=new File(LOG,'a');f.write(s+'\n');f.flush();f.close();}catch(e){} try{console.log('[STREAM] '+s);}catch(e){} }
    try{var f0=new File(LOG,'w');f0.write('=== stream + state probe ===\n');f0.close();}catch(e){}
    var base; try{base=getModuleBase();}catch(e){base=null;} if(!base){ slog('no base'); return; }
    var PATHS={ '0xe1d11df4d38d1d94':'_root.ent', '0x771984f3462f40ff':'.app', '0xc67175c8c7bf85c5':'_top.ent', '0x1c41dc56f1d3b1ae':'top_base_body.mesh' };
    var seen={}, n=0;
    try{
        Interceptor.attach(base.add(0x21b4d58), { onEnter:function(a){ try{ var h=a[1].toString(); if(PATHS[h] && n<60){ n++; slog('RESLOOKUP '+PATHS[h]+' ('+h+')'); } }catch(e){} } });
        slog('resource-lookup hook @ base+0x21b4d58 OK (watch _root.ent/.app/_top.ent/mesh)');
    }catch(e){ slog('reslookup hook err '+e); }
    var states={}, sN=0;
    try{
        Interceptor.attach(base.add(0x36e783c), { onEnter:function(a){ try{
            var req=a[0]; var st=req.add(0x108).readU32(); var key=req.toString()+':'+st;
            if(!states[key] && sN<120){ states[key]=1; sN++; slog('STATE req='+req+' -> '+st); }
        }catch(e){} } });
        slog('itemfactory state-machine hook @ base+0x36e783c OK (req+0x108 state; stuck@2=loading-forever, 3=FindAppearance)');
    }catch(e){ slog('state hook err '+e); }
    // PLAYER garment build flow (the one actually running on equip). ComputePlayerGarment 0x3710004,
    // ProcessGarment 0xae6660, item-factory state-3 LoadAppearance/FindAppearance bridge 0x36e7e58.
    // Log when each fires (capped) to see whether the player garment rebuild reaches our item.
    var cpgN=0,pgN=0,br3=0;
    try{ if(CET_OWNS_GARMENT) Interceptor.attach(base.add(0x3710004),{ onEnter:function(a){ if(cpgN<15){cpgN++; slog('ComputePlayerGarment FIRED #'+cpgN+' x0='+a[0]);} } }); slog('ComputePlayerGarment hook @0x3710004 '+(CET_OWNS_GARMENT?'OK':'SKIPPED (RED4ext owns)')); }catch(e){ slog('cpg hook err '+e); }
    try{ if(CET_OWNS_GARMENT) Interceptor.attach(base.add(0xae6660),{ onEnter:function(a){ if(pgN<20){pgN++; slog('ProcessGarment FIRED #'+pgN+' x0='+a[0]);} } }); slog('ProcessGarment hook @0xae6660 '+(CET_OWNS_GARMENT?'OK':'SKIPPED (RED4ext owns)')); }catch(e){ slog('pg hook err '+e); }
    try{ Interceptor.attach(base.add(0x36e7e58),{ onEnter:function(a){ if(br3<15){br3++; slog('LoadAppearanceBridge(state3) FIRED #'+br3+' req='+a[0]);} } }); slog('LoadAppearanceBridge hook @0x36e7e58 OK'); }catch(e){ slog('br3 hook err '+e); }
})();

})();

// ===== macOS PLUGIN-NATIVE REGISTRATION (break the "plugin RTTI invisible to redscript" wall) =====
// Register a plugin-provided native at CBaseEngine::InitScripts entry - the one window where the RTTI system
// is fully constructed (CRTTISystem::Get is safe) yet no script has bound its native-func declarations.
// Plugin-load is too early (Get() force-constructs RTTI -> SIGSEGV); menu/archiveload is too late (the binder
// already trapped on the unresolved native). Ghidra ctorhunt offsets: RTTI ready-flag byte @0x7d6a268 (bit0),
// CRTTISystem::Get 0x2188e8c, CGlobalFunction ctor 0x21739e8 (sizeof 0xB8), CNamePool::Add 0x3452ddc,
// RegisterFunction = CRTTISystem vtable+0xA0, GetFunction = vtable+0x30, InitScripts entry 0x3d8c188.
// Disable with /tmp/cp2077_no_natreg.

// Shared registry for the bug-#1 finalize preserve hooks (installFinalizeFix below). They hook FUN_1000286e8
// (the engine DynArray re-capacity), which is EXTREMELY hot - every DynArray resize in the whole engine goes
// through the Frida trampoline. The finalize we care about happens ONCE, inside CBaseEngine::InitScripts; after
// that the hooks are pure overhead (observed: ~4x slower save-load). So installFinalizeFix registers its
// listeners here, and installNativeReg DETACHES them at InitScripts onLeave (finalize done) -> no gameplay cost.
var g_finalizeHookListeners = [];
var g_finalizeHooksDetached = false;
function g_detachFinalizeHooks() {
    if (g_finalizeHooksDetached) return 0;
    g_finalizeHooksDetached = true;
    var n = 0;
    g_finalizeHookListeners.forEach(function (l) { try { l.detach(); n++; } catch (e) {} });
    g_finalizeHookListeners = [];
    return n;
}

(function installNativeReg(){
    function nlog(s){ try{ var f=new File('/tmp/cp2077_redlib.log','a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} }
    try {
        var disabled = false; try { File.readAllText('/tmp/cp2077_no_natreg'); disabled = true; } catch(e){}
        if (disabled) { nlog('[NATREG] disabled (/tmp/cp2077_no_natreg)'); return; }
        var base = getModuleBase();
        var READY = base.add(0x7d6a268);   // CRTTISystem init-done flag (bit0=1 => Get is safe)

        // Resolve the C export that registers plugin natives (create+describe+register). The registration
        // lives in C++; we only provide the TIMING - call it at InitScripts entry, the RTTI-ready-but-pre-bind
        // window. Two sources:
        //   - ArchiveXL.dylib cybermodman_registerNatives  (the Tier-1 stub: 20 globals + reflection stubs)
        //   - Codeware.dylib  codeware_registerNatives      (the REAL Codeware runtime, all subsystems)
        // They register OVERLAPPING names (FNV, Reflection, ...), so only ONE may run. When
        // /tmp/cp2077_codeware_real exists, prefer the real Codeware export and skip the stub.
        var useCodeware = false; try { File.readAllText('/tmp/cp2077_codeware_real'); useCodeware = true; } catch(e){}
        function findExport(modSubstr, sym){
            var p = null;
            try { p = Module.findExportByName(modSubstr + '.dylib', sym); } catch(e){}
            if (!p) { try { Process.enumerateModules().forEach(function(m){
                if (!p && (m.name||'').indexOf(modSubstr) >= 0) { try { p = m.findExportByName(sym); } catch(e){} }
            }); } catch(e){} }
            return p;
        }

        var done = false;
        Interceptor.attach(base.add(0x3d8c188), { onEnter: function(a){
            if (done) return; done = true;
            try {
                var ready = READY.readU8() & 1;
                nlog('[NATREG] InitScripts entry; RTTI-ready flag=' + ready + (useCodeware ? ' (real Codeware)' : ' (ArchiveXL stub)'));
                if (!ready) { nlog('[NATREG] RTTI not ready -> skip (Get would crash)'); return; }
                var reg, sym;
                if (useCodeware) { sym = 'codeware_registerNatives'; reg = findExport('Codeware', sym); }
                else             { sym = 'cybermodman_registerNatives'; reg = findExport('ArchiveXL', sym); }
                nlog('[NATREG] ' + sym + ' export = ' + reg);
                if (reg) {
                    new NativeFunction(reg, 'void', [])();
                    nlog('[NATREG] called ' + sym);
                } else {
                    nlog('[NATREG] export NOT FOUND (' + (useCodeware ? 'Codeware.dylib loaded?' : 'ArchiveXL natives build?') + ')');
                }

                // TweakXL registers a DISJOINT set of types (TweakXL, TweakDBManager, TweakDBBatch,
                // ScriptableTweak), so it does NOT hit the name overlap that forces Codeware and ArchiveXL to be
                // mutually exclusive - it runs IN ADDITION rather than instead. Without it, TweakXL's shipped
                // reds declare natives that never reach CRTTISystem and the script binder dies while building
                // its own "Missing native function" message the moment any mod references TweakDBManager
                // (first seen with Equipment EX). Runs after the primary export so core types land first, and
                // is skipped with a log line on TweakXL builds that predate the export.
                try {
                    var txlReg = findExport('TweakXL', 'tweakxl_registerNatives');
                    if (txlReg) {
                        new NativeFunction(txlReg, 'void', [])();
                        nlog('[NATREG] called tweakxl_registerNatives');
                    } else {
                        nlog('[NATREG] tweakxl_registerNatives NOT FOUND (old TweakXL build; its reds natives will not bind)');
                    }
                } catch (eT) { nlog('[NATREG] tweakxl_registerNatives ERROR ' + eT); }

                // ArchiveXL's OWN reds-visible class (App::Facade -> "ArchiveXL", declared native by
                // scripts/Facade.reds). This is NOT cybermodman_registerNatives: that one is the Codeware
                // Tier-1 stub whose globals collide with real Codeware (hence the mutual exclusion above,
                // which stays), and it registers no ArchiveXL type in either mode - so the binder reported
                // "Missing native class 'ArchiveXL'" as soon as those reds were staged. This export is
                // overlap-free by construction and runs additively. Skipped with a log line on older builds.
                try {
                    var axlReg = findExport('ArchiveXL', 'archivexl_registerNatives');
                    if (axlReg) {
                        new NativeFunction(axlReg, 'void', [])();
                        nlog('[NATREG] called archivexl_registerNatives');
                    } else {
                        nlog('[NATREG] archivexl_registerNatives NOT FOUND (old ArchiveXL build; its reds natives will not bind)');
                    }
                } catch (eA) { nlog('[NATREG] archivexl_registerNatives ERROR ' + eA); }

                if (!reg) return;

                // ---- Bug #2 validation (Ghidra + workflow-verified 2026-07-05): the persistence-schema rebuild
                // job (PersistencySystem::OnInitialize FUN_103fec750, enqueued LATER on THIS main thread, runs on
                // a worker) does GetClasses(gamePersistentState) and tears down every subclass via the CClass
                // teardown FUN_10219721c. Codeware's DynamicEntitySystemPS (hash 0x77152b1b8dcbb39d) derives from
                // Red::PersistentState == gamePersistentState (0xfce73aa1e8b0cd2f), so it is swept; its teardown
                // faults on our-provenance memory (bug #2, un-hookable on the worker). Here, MAIN-THREAD and
                // BEFORE the job is enqueued: (a) log the whole sweep set to confirm which of OUR classes are in
                // it; (b) if /tmp/cp2077_ps_reparent is set, sever DynamicEntitySystemPS's persistent ancestry
                // (parent@+0x10 -> gamePersistentState's own parent) so GetClasses no longer selects it. All
                // read-only + one pointer write on the main thread => gum-safe. Confirms the mechanism + fix.
                try {
                    var reparent = false; try { File.readAllText('/tmp/cp2077_ps_reparent'); reparent = true; } catch(e2){}
                    var getRTTI = new NativeFunction(base.add(0x2188e8c), 'pointer', []);
                    var getGPS  = new NativeFunction(base.add(0x1f8ead8), 'pointer', []);
                    var sys = getRTTI(), gps = getGPS();
                    function clsHash(c){ try{ var v=c.readPointer(); var gn=new NativeFunction(v.add(0x10).readPointer(),'uint64',['pointer']); return gn(c).toString(16); }catch(e2){ return '<e>'; } }
                    if (!sys.isNull() && !gps.isNull()) {
                        var gh = clsHash(gps);
                        nlog('[PS-SWEEP] gamePersistentState cls=' + gps + ' hash=0x' + gh + ' (expect fce73aa1e8b0cd2f) reparentFlag=' + reparent);
                        var vt = sys.readPointer();
                        var getClasses = new NativeFunction(vt.add(0x70).readPointer(), 'void', ['pointer','pointer','pointer','int','int']);
                        var out = Memory.alloc(0x10); out.writeU64(0); out.add(8).writeU64(0);
                        getClasses(sys, gps, out, 0, 0);
                        var arr = out.readPointer(), n = out.add(0xc).readU32();
                        var gpsParent = gps.add(0x10).readPointer();
                        nlog('[PS-SWEEP] GetClasses(gamePersistentState) count=' + n + ' gpsParent=' + gpsParent);
                        var lim = (n > 8192) ? 8192 : n, reN = 0, logged = 0;
                        for (var i = 0; i < lim; i++) {
                            var cls = arr.add(i*8).readPointer(); if (cls.isNull()) continue;
                            var h = clsHash(cls);
                            var mine = (h === '77152b1b8dcbb39d');
                            if (logged < 80 || mine) { nlog('  [PS-SUB] ' + cls + ' hash=0x' + h + (mine ? '  <== DynamicEntitySystemPS (OURS)' : '')); logged++; }
                            if (mine && reparent) {
                                try { cls.add(0x10).writePointer(gpsParent); reN++; nlog('  [PS-REPARENT] DynamicEntitySystemPS parent@+0x10 -> ' + gpsParent + ' (severed gamePersistentState ancestry; de-selected from sweep)'); }
                                catch(e2){ nlog('  [PS-REPARENT] write err ' + e2); }
                            }
                        }
                        nlog('[PS-SWEEP] done: subclasses=' + n + ' reparented=' + reN);
                    } else { nlog('[PS-SWEEP] sys=' + sys + ' gps=' + gps + ' (skipped)'); }
                } catch(e2){ nlog('[PS-SWEEP] ERROR ' + e2); }
            } catch(e){ nlog('[NATREG] ERROR ' + e); }
        }});
        // NOTE: the finalize preserve hooks are detached by installFinalizeFix itself, at the LEAVE of the
        // per-class finalize DRIVER FUN_1021950fc (the true "finalize done" point) - NOT here at InitScripts
        // onLeave, which fires too early (the driver runs later inside InitScripts; detaching here left #1 unfixed).
        nlog('[NATREG] armed InitScripts hook @0x3d8c188 (' + (useCodeware ? 'codeware_registerNatives' : 'cybermodman_registerNatives') + ')');
    } catch(e){ nlog('[NATREG] install err ' + e); }
})();

// BIND DIAGNOSTIC (Ghidra 2026-07-04): the redscript binder has per-kind validators for native imports.
// Each takes the entity DESCRIPTOR in x1 with the failing name as a CName (u64 hash) at [x1+0x8], and
// returns null/0 on failure. CNamePool::Get (0x3452bdc) resolves the hash -> const char*. On macOS the
// specific unresolved-native reason is NOT written to any log before the SIGTRAP at 0x3da2a60, so this
// hooks the validators directly and writes the failing name to /tmp/cp2077_bindfail.log. Gated on
// /tmp/cp2077_bindfail (create it to enable) so it never runs in normal play. Name resolved only on
// failure (onLeave), so the thousands of successful resolves cost nothing.
(function installBindDiag(){
    function blog(s){ try{ var f=new File('/tmp/cp2077_bindfail.log','a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} }
    try {
        // Gated on a SEPARATE flag now: this validator-hook approach OVER-REPORTS (null return != genuine miss;
        // it lists IScriptable/Entity/... = the binder's failure cascade). Use installBindFormatterDiag below
        // (the CString::Format hook) for the GENUINE unresolved-native names.
        var on=false; try{ File.readAllText('/tmp/cp2077_bindfail_validators'); on=true; }catch(e){}
        if(!on) return;
        var base = getModuleBase();
        var cnameGet = new NativeFunction(base.add(0x3452bdc), 'pointer', ['uint64']);
        function nameOf(desc){
            try { var h = desc.add(0x8).readU64(); var p = cnameGet(h);
                  return (p && !p.isNull()) ? p.readUtf8String() : ('<hash 0x'+h.toString(16)+'>'); }
            catch(e){ return '<err '+e+'>'; }
        }
        var kinds = [
            [0x21fcee0, 'global-func'], [0x21fc61c, 'class'], [0x21fc1a4, 'typeref'],
            [0x21fc290, 'enum'], [0x21fc47c, 'bitfield'],
        ];
        kinds.forEach(function(k){
            try { Interceptor.attach(base.add(k[0]), {
                onEnter: function(a){ this.desc = a[1]; },
                onLeave: function(r){ if (r.isNull()) blog('[BIND-FAIL] missing native ' + k[1] + ': ' + nameOf(this.desc)); }
            }); } catch(e){ blog('[BIND-DIAG] attach err '+k[1]+' '+e); }
        });
        // Unresolved param/return/local type: log the owning FUNCTION name at entry (type name is built, not a CName).
        try { Interceptor.attach(base.add(0x21ea1b8), {
            onEnter: function(a){ blog('[BIND-FAIL] unresolved type in function: ' + nameOf(a[1])); }
        }); } catch(e){ blog('[BIND-DIAG] attach err unres-type '+e); }
        blog('[BIND-DIAG] armed ' + (kinds.length+1) + ' validator hooks');
    } catch(e){ blog('[BIND-DIAG] install err ' + e); }
})();

// BIND FORMATTER DIAGNOSTIC (Ghidra-verified 2026-07-05): the reds binder logs each genuine unresolved-native
// error via CString::Format = FUN_10002dccc(out=x0, fmt=x1, ...args) (a vsnprintf wrapper). The validator-hook
// diag above OVER-REPORTS (cascade); this captures ONLY the real errors by filtering the FORMAT string (x1) and
// reading the substituted name (x2). Writes to /tmp/cp2077_bindfmt.log. Gated on /tmp/cp2077_bindfail.
(function installBindFormatterDiag(){
    function flog(s){ try{ var f=new File('/tmp/cp2077_bindfmt.log','a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} }
    try {
        var on=false; try{ File.readAllText('/tmp/cp2077_bindfail'); on=true; }catch(e){}
        if(!on) return;
        var base = getModuleBase();
        // broadened 2026-07-06 to catch EVERY class-validator error verbatim (FUN_1021fc61c): base-class-different,
        // not-marked-abstract, has-to-be-declared-as, property-type-mismatch, missing native member, etc.
        var KEYS = ['native','import','bind','missing','unresolved','resolve',
                    'base class','has to be declared','abstract','property','function','does not match','not native','marked as'];
        var seen={}, count=0, armed=0;
        Interceptor.attach(base.add(0x2dccc), {
            onEnter: function(a){
                try{
                    var fmt=null; try{ fmt=a[1].readUtf8String(); }catch(e){ return; }
                    if(!fmt) return;
                    var low=fmt.toLowerCase(); var hit=false;
                    for(var i=0;i<KEYS.length;i++){ if(low.indexOf(KEYS[i])>=0){ hit=true; break; } }
                    if(!hit) return;
                    // x2 = first vararg (the substituted name); try string, else hex.
                    var a2='?'; try{ a2=a[2].readUtf8String(); }catch(e){ try{ a2='0x'+a[2].toString(16); }catch(x){} }
                    var a3='';  try{ var s3=a[3].readUtf8String(); if(s3) a3=' arg3="'+s3+'"'; }catch(e){}
                    var key=fmt+'|'+a2;
                    if(seen[key]) return; seen[key]=1;
                    if(count<400){ flog('[FMT] fmt="'+fmt+'" arg2="'+a2+'"'+a3); count++; }
                }catch(e){}
            }
        });
        armed=1;
        flog('[BIND-FMT] armed CString::Format hook @0x2dccc (filters: '+KEYS.join(',')+')');
    } catch(e){ flog('[BIND-FMT] install err '+e); }
})();

// BIND-REJECT DIAGNOSTIC (Ghidra-verified 2026-07-06): names EVERY script-definition the engine binder rejects,
// in ONE launch. The per-item validation loop FUN_1021fbf90 (@0x1021fbf90) walks the parsed ScriptDefinition list
// and dispatches each to a per-kind validator (0=typeref/1=class/3=enum/4=bitfield/5=func); every validator's
// pass/fail (w0: 1=pass, 0=REJECT) converges at 0x1021fc0c0 where the loop accumulates failures:
//     1021fc0c0  eor w8,w0,#0x1        <- HOOK HERE (onEnter): w0 = this item's result, x21 = this item
//     1021fc0c4  add w23,w23,w8        <- w23 (failure count); any nonzero -> 'Validation failed for %u types'
//     ...        -> FUN_1021fbf90 returns 0 -> FUN_103d9e494 hits FUN_103da2a34 -> SIGTRAP 0x3da2a60.
// The item's CName is at [x21+8] (proven: kind-0 validator FUN_1021fc1a4 does GetType(*(CName*)(item+8)) then
// resolves it via the engine reverse-lookup for its 'Missing native typeref %hs' error). x21 is callee-saved and
// reloaded each iteration, so it still points at the just-validated item at 0x1021fc0c0. We hook the LOOP (which
// RETURNS NORMALLY) with onEnter ONLY - NOT an onLeave on a validator (validators tail-call; onLeave on a
// tail-calling fn is the macOS-27 gum hazard that corrupted the older installBindDiag). This runs on the MAIN
// thread (synchronous baseEngineInit), so the gum trampoline is safe here. w0==0 uniquely isolates the FAILING
// item, so unlike installBindDiag this does NOT over-report the cascade. The loop visits all items and w23 sums
// ALL failures before the panic, so one launch enumerates the COMPLETE reject set. Gated on /tmp/cp2077_bindreject.
(function installBindRejectDiag(){
    var LOG='/tmp/cp2077_bindreject.log';
    function wlog(s){ try{ var f=new File(LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{console.log('[BIND-REJECT] '+s);}catch(e){} }
    try {
        var on=false; try{ File.readAllText('/tmp/cp2077_bindreject'); on=true; }catch(e){}
        if(!on) return;
        try{ var f0=new File(LOG,'w'); f0.write('=== bind-reject count (RELIABLE) ===\n'); f0.close(); }catch(e){}
        var base=getModuleBase();
        // COUNT ONLY, from a SAFE post-loop instruction. Any frida hook INSIDE the loop (0x21fc00c..0x21fc0d0)
        // corrupts an adjacent instruction on macOS-27 (EXC_BAD_INSTRUCTION @0x21fc0cc) - the stock-gum trampoline
        // flaw. So do NOT touch the loop. Read the engine's own failure counter w23 at 0x1021fc0d8 (a plain 'adrp'
        // on the failure path, executed ONCE after the loop when w23!=0). This is the TRUE reject count, uncorrupted.
        var got=false;
        Interceptor.attach(base.add(0x21fc0d8), {
            onEnter: function(){
                if(got) return; got=true;
                try{ var w23 = parseInt(this.context.x23.toString()) >>> 0;
                     wlog('ENGINE total bind-failure count (w23) = '+w23); }
                catch(e){ wlog('w23 read err '+e); }
            }
        });
        wlog('armed: w23-count @0x21fc0d8 (post-loop, no loop hook)');
    } catch(e){ wlog('install err '+e); }
})();

// BIND-ERROR CAPTURE (2026-07-06): the DEFINITIVE reason each class fails. FUN_10223a748(param1, blob, collector=x2)
// runs the validator loop and every validator reports errors via collector->vtable[2](collector, char* msg, len)
// (seen in FUN_10223a748: (**(code**)(*param_3+0x10))(param_3,"Failed to load scripts",0x16)). We hook FUN_10223a748
// (a FUNCTION ENTRY - safe, unlike a loop-instruction hook), resolve collector->vtable[2] at runtime, and attach a
// logger to it. Each call logs the FULLY-FORMATTED error (class/member names substituted). Gated /tmp/cp2077_binderr.
(function installBindErrorCapture(){
    var LOG='/tmp/cp2077_binderr.log';
    function elog(s){ try{ var f=new File(LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} }
    try {
        var on=false; try{ File.readAllText('/tmp/cp2077_binderr'); on=true; }catch(e){}
        if(!on) return;
        try{ var f0=new File(LOG,'w'); f0.write('=== bind error capture (collector->vtable[2]) ===\n'); f0.close(); }catch(e){}
        var base=getModuleBase();
        var hooked=false, count=0;
        Interceptor.attach(base.add(0x223a748), {
            onEnter: function(a){
                try{
                    if(hooked) return;
                    var collector=a[2];
                    if(!collector || collector.isNull()) return;
                    var vtbl=collector.readPointer();
                    hooked=true;
                    // The collector object is shared across the whole script-init pipeline. Different stages
                    // report through different vtable slots, with different arg positions for the message:
                    //   slot 2 @0x10  validator per-type error       report(this, char* msg, int len)      msg=b[1]
                    //   slot 3 @0x18  summary ("Binding failed for N") report(this, char* msg, int len)      msg=b[1]
                    //   slot 4 @0x20  binder per-FUNCTION error       report(this, funcDef, char* msg, int) msg=b[2]
                    // Hook all three so we capture BOTH the validation pass AND the later function-binding pass
                    // (FUN_1021ea1b8: "Unresolved return/parameter/local type", "Failed to create function", etc).
                    var m2=vtbl.add(0x10).readPointer();
                    var m3=vtbl.add(0x18).readPointer();
                    var m4=vtbl.add(0x20).readPointer();
                    elog('[CAPTURE] collector v2@'+m2+' v3@'+m3+' v4@'+m4);
                    Interceptor.attach(m2, { onEnter: function(b){ try{ var s=b[1].readUtf8String(); if(s&&count<4000){count++;elog('[validate] '+s);} }catch(e){} } });
                    if(!m3.equals(m2)) Interceptor.attach(m3, { onEnter: function(b){ try{ var s=b[1].readUtf8String(); if(s&&count<4000){count++;elog('[summary]  '+s);} }catch(e){} } });
                    if(!m4.equals(m2)&&!m4.equals(m3)) Interceptor.attach(m4, { onEnter: function(b){ try{ var s=b[2].readUtf8String(); if(s&&count<4000){count++;elog('[bind-fn]  '+s);} }catch(e){} } });
                }catch(e){ elog('resolve err '+e); }
            }
        });
        elog('[CAPTURE] armed on FUN_10223a748');
    } catch(e){ elog('install err '+e); }
})();

// SVCINIT (2026-08-01): drive Codeware's ScriptableService lifecycle at the post-bind moment.
// On Windows this is HookAfter<ScriptBundle::Destruct>; on macOS that dtor is INLINED into the bind driver
// FUN_10223a748 (its surviving fragment 0x21f3460 sits in a never-taken branch), and inline-hooking the
// loader 0x3d9a028 HANGS the game (proven twice). So: Frida onLeave on the bind driver - the exact same
// "scripts just loaded and bound" moment - calling Codeware's codeware_initScriptableServices export.
// Without this, NO ScriptableService is ever constructed on macOS, no OnLoad runs, and every mod built on
// ScriptableService (and callbacks registered from OnLoad) silently does nothing.
// Escape hatch: touch /tmp/cp2077_no_svcinit
(function(){
    // Self-contained logger: nlog/elog are function-scoped inside their own IIFEs and NOT visible here.
    // Referencing them killed the whole script at gadget load (ReferenceError), which took the BIND-PATCH
    // below down with it -> 3510 validation failures -> binder formatter crash. Never share loggers across
    // these blocks.
    function slog(s){ try{ var f=new File('/tmp/cp2077_redlib.log','a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} }
    try {
        var off=false; try{ File.readAllText('/tmp/cp2077_no_svcinit'); off=true; }catch(e){}
        if(off){ slog('[SVCINIT] disabled (/tmp/cp2077_no_svcinit)'); return; }
        var base=getModuleBase();
        var done=false;
        // 0x223a748 = the script BIND DRIVER: validate + bind happen INSIDE it, so its onLeave is the
        // earliest provably POST-BIND moment - scripted classes are in RTTI and their methods are bound.
        // TIMING FACTS, each proven by a breadcrumb run (do not re-litigate):
        //   - InitScripts (0x3d8c188) onLeave is PRE-BIND: the boot state machine calls LoadScripts+bind
        //     AFTER InitScripts returns (crash stacks show LoadScripts under 0x3f20348/0x3d9dd30, not under
        //     0x3d8c188), so GetClasses(ScriptableService) = 0 there.
        //   - GetGlobalFunction("InitializeScripts;") answers NULL even post-bind on macOS, so the C++ side
        //     treats that gate as ADVISORY (see ScriptingService.cpp) - do not rely on it firing.
        Interceptor.attach(base.add(0x223a748), {
            onLeave: function(ret){
                if(done) return;
                done=true;
                try{
                    var p=null;
                    try{ p=Module.findExportByName('Codeware.dylib','codeware_initScriptableServices'); }catch(e){}
                    if(!p){ try{ var mods=Process.enumerateModules(); for(var i=0;i<mods.length;i++){ var m=mods[i]; if((m.name||'').indexOf('Codeware')>=0){ p=m.findExportByName('codeware_initScriptableServices'); if(p) break; } } }catch(e){} }
                    if(!p||p.isNull()){ slog('[SVCINIT] export not found - Codeware.dylib too old?'); return; }
                    new NativeFunction(p,'void',[])();
                    slog('[SVCINIT] scriptable-service container init dispatched (post-bind)');
                }catch(e){ slog('[SVCINIT] err '+e); }
            }
        });
        slog('[SVCINIT] armed on bind driver 0x223a748 (onLeave, post-bind)');
    } catch(e){ slog('[SVCINIT] install err '+e); }
})();

// BIND-PATCH (2026-07-07): the 3-branch binder relaxation that lets the CORRECTED Codeware.Global.reds BIND.
// The macOS kind-1 CLASS validator FUN_1021fc61c (imageBase+0x21fc61c) enforces 3 checks that engine
// STRUCTS-WITH-A-PARENT and ABSTRACT STRUCTS provably cannot satisfy in redscript (a struct can't `extends`, can't
// be `abstract`) - Windows accepts the same RTTI dump, macOS rejects it. We turn each offending conditional branch
// into an UNCONDITIONAL `b` that skips ONLY that error; type-exists / property-type / member-name checks stay fully
// ACTIVE (this is NOT "disable validation"). Applied as a byte patch via Memory.patchCode (NOT Interceptor - no gum
// trampoline, safe on macOS-27) at gadget load, BEFORE baseEngineInit runs the binder. Gated /tmp/cp2077_bindpatch.
// Each branch is GUARDED: its current 4 bytes must equal the known tbz/tbnz encoding or that patch is SKIPPED - so a
// future game update that shifts these offsets can never corrupt the wrong instruction. Verified against Steam 2.3.1
// build 5314028: (A) 0x21fc754 tbz w0,#0,0x1021fc7dc -> b 0x1021fc83c ; (B) 0x21fc98c tbz w8,#0,0x1021fc9f4 ->
// b 0x1021fc9f4 ; (C) 0x21fcb80 tbnz w0,#0,0x1021fcc14 -> b 0x1021fcc14. b = 0x14000000 | ((tgt-pc)>>2).
(function installBindPatch(){
    var LOG='/tmp/cp2077_bindpatch.log';
    function plog(s){ try{ var f=new File(LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{console.log('[BIND-PATCH] '+s);}catch(e){} }
    try {
        var on=false; try{ File.readAllText('/tmp/cp2077_bindpatch'); on=true; }catch(e){}
        if(!on) return;
        try{ var f0=new File(LOG,'w'); f0.write('=== bind patch (6-branch validator relaxation) ===\n'); f0.close(); }catch(e){}
        var base=getModuleBase();
        if(!base){ plog('ERROR: no module base'); return; }
        // [ file-off, expected CURRENT word (LE U32), NEW branch word (LE U32), label ]
        // A/B/C = the class-KIND checks (struct/abstract/base-not-declared) redscript can't express.
        // D/E/F = the per-member checks that were MASKED by A's early-out and only surface once A passes:
        //   D base-diff   ("declared base class X that is different than current one Y", str 0x106cc4fc5) ->
        //                 ISerializable (reds/redscript model says base IScriptable; macOS engine has it as a
        //                 root, base <none>). Guard = the cmp of declared-vs-engine base at 0x21fcb18; b.eq
        //                 0x1021fcc14 -> b (always take the "match" path, skip error + fail-flag). NOTE: an
        //                 earlier build mis-patched 0x21fca08 which guards a DIFFERENT string 0x106cc4f50
        //                 ("...that is not imported") - that never fired; 0x21fcb1c is the correct guard.
        //   E proptype    ("Imported property type does not match") -> Windows-lenient resource-ref/enum types
        //                 (ResourceRef vs rRef:CMesh etc, layout-identical); tbnz w0,#0,0x1021fcc9c -> b (same tgt).
        //   F miss-func   ("Missing native function") -> Codeware @addMethod natives the macOS dylib doesn't
        //                 register yet; cbz x0,<errEmit> RETARGETED to the loop-continue 0x1021fcdf0 so a
        //                 not-found func is skipped instead of rejected. NOTE: the ~6 that Codeware actually CALLS
        //                 (FromNumber/AttachController/GetEntries/GetAction/GetScale) are then declared-but-unbacked
        //                 -> harmless at boot/menu (no content mod exercises them); durable fix = register in dylib.
        var patches=[
            [0x21fc754, 0x36000440, 0x1400003a, 'A struct-check   tbz w0,#0 -> b 0x1021fc83c'],
            [0x21fc98c, 0x36000348, 0x1400001a, 'B abstract-check tbz w8,#0 -> b 0x1021fc9f4'],
            [0x21fcb80, 0x370004a0, 0x14000025, 'C base-notdecl   tbnz w0,#0 -> b 0x1021fcc14'],
            [0x21fcb1c, 0x540007c0, 0x1400003e, 'D base-diff      b.eq 0x1021fcc14 -> b (skip different-than-current)'],
            [0x21fcce0, 0x3707fde0, 0x17ffffef, 'E proptype       tbnz w0,#0 -> b 0x1021fcc9c'],
            [0x21fce20, 0xb4fffb20, 0xb4fffe80, 'F miss-func      cbz x0 -> loop-continue 0x1021fcdf0'],
        ];
        var applied=0;
        patches.forEach(function(p){
            var off=p[0], want=p[1]>>>0, neu=p[2]>>>0, label=p[3];
            try{
                var addr=base.add(off);
                var cur=addr.readU32()>>>0;
                if(cur!==want){
                    plog('SKIP '+label+' @0x'+off.toString(16)+': current=0x'+cur.toString(16)+' != expected=0x'+want.toString(16)+' (offset moved? NOT patching)');
                    return;
                }
                Memory.patchCode(addr, 4, function(ptr){ ptr.writeU32(neu); });
                var after=addr.readU32()>>>0;
                if(after===neu){ applied++; plog('OK   '+label+' @0x'+off.toString(16)+': 0x'+want.toString(16)+' -> 0x'+neu.toString(16)); }
                else { plog('FAIL '+label+' @0x'+off.toString(16)+': readback=0x'+after.toString(16)+' expected=0x'+neu.toString(16)); }
            }catch(e){ plog('ERR  '+label+': '+e); }
        });
        plog('done: '+applied+'/6 branches patched');
    } catch(e){ plog('install err '+e); }
})();

// Property-layout finalize fix+diagnostic (Ghidra-verified 2026-07-04). Per-class finalize wrapper FUN_10219e270:
//   FUN_10219dce0(cls,1)  builds unk118@0x118 via collector FUN_102197928 (walks parent chain, memcpys each
//                         class's own props@0x28 sized by size@0x34), then WALKS unk118 derefing entry->type@0
//                         (crash 0x219de10 ldr x0,[x8] x8=0 when an entry POINTER is null) + entry->name@8.
//   FUN_102198670(cls,cls+0x128)  builds list@0x128 (a SPARSE savable-subset; slot 0 legitimately null - a RED
//                         HERRING, nothing that crashes reads it; do NOT touch it).
//   FUN_10219dfb4(cls)    WALKS THE SAME unk118 reading entry->flags byte@0x2a with NO null-ptr guard
//                         (crash 0x219e014 ldrb [x24,#0x2a] x24=0 when an entry POINTER is null).
// So BOTH crashes are one defect: a NULL POINTER inside unk118, which the collector can only get by copying a
// null out of some parent-chain class's props@0x28 (size@0x34 over-counts / embedded null). Engine classes are
// clean (game boots normally); the null is in a CODEWARE class's OWN props@0x28. FIX = at FUN_10219dce0 onEnter,
// BEFORE the collector runs, walk the class's parent chain (+0x10) and COMPACT props@0x28 at each node - drop
// only null-pointer / null-type entries (never valid ones) and fix size@0x34 - so the collector builds a clean
// unk118 and both walks survive. dfb4 gets a belt-and-suspenders unk118 compact. The log names the exact
// class+prop for the durable source fix. Gated on /tmp/cp2077_finaldiag; logs to /tmp/cp2077_finaldiag.log.
(function installFinalizeFix(){
    function flog(s){ try{ var f=new File('/tmp/cp2077_finaldiag.log','a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} }
    try {
        // The bug-#1 preserve fix runs whenever Codeware is active (/tmp/cp2077_codeware_real); the verbose
        // per-class diagnostics are extra and only run under /tmp/cp2077_finaldiag. Either flag arms the hooks;
        // installNativeReg detaches them all at InitScripts onLeave so there is no gameplay overhead.
        var diag=false; try{ File.readAllText('/tmp/cp2077_finaldiag'); diag=true; }catch(e){}
        var fix=false;  try{ File.readAllText('/tmp/cp2077_codeware_real'); fix=true; }catch(e){}
        if(!diag && !fix) return;
        var base = getModuleBase();
        var cnameGet = new NativeFunction(base.add(0x3452bdc), 'pointer', ['uint64']);
        function nm(h){ try{ var p=cnameGet(h); return (p&&!p.isNull())?p.readUtf8String():('#0x'+h.toString(16)); }catch(e){ return '<e>'; } }
        function typeName(t){ try{ if(t.isNull()) return '<null>'; var vt=t.readPointer(); if(vt.isNull()) return '<nv>';
            var gn=new NativeFunction(vt.add(0x10).readPointer(),'uint64',['pointer']); return nm(gn(t)); }catch(e){ return '<e>'; } }
        function nameHash(t){ try{ var vt=t.readPointer(); if(vt.isNull()) return '<nv>'; var gn=new NativeFunction(vt.add(0x10).readPointer(),'uint64',['pointer']); var h=gn(t); return '0x'+h.toString(16)+'('+nm(h)+')'; }catch(e){ return '<e>'; } }
        // DynArray {ptr@off, cap@off+8 u32, size@off+0xc u32}.
        function darr(p, off){ try{ return { ptr:p.add(off).readPointer(), cap:p.add(off+8).readU32(), size:p.add(off+0xc).readU32() }; }catch(e){ return null; } }
        // Which arg is the real CClass: readable vtable + self-consistent props@0x28 and unk118@0x118 DynArrays.
        function looksLikeClass(p){ try{ if(p.isNull()) return false; var vt=p.readPointer(); if(vt.isNull()) return false; vt.readPointer();
            var a=darr(p,0x28), b=darr(p,0x118); if(!a||!b) return false;
            if(a.size>a.cap+1 || b.size>b.cap+1) return false; if(a.cap>200000 || b.cap>200000) return false; return true; }catch(e){ return false; } }
        function pickClass(a){ if(looksLikeClass(a[0])) return {cls:a[0],arg:0}; if(looksLikeClass(a[1])) return {cls:a[1],arg:1}; return null; }
        function arrHasNull(cls, off){ var d=darr(cls,off); if(!d||d.ptr.isNull()||d.size===0||d.size>200000) return false;
            for(var i=0;i<d.size;i++){ try{ var e=d.ptr.add(i*8).readPointer(); if(e.isNull()) return true; if(e.readPointer().isNull()) return true; }catch(x){ return true; } } return false; }
        function dumpArr(tag, cls, off){ var d=darr(cls,off); if(!d){ flog('  '+tag+' <no darr>'); return; }
            flog('  '+tag+' ptr='+d.ptr+' cap='+d.cap+' size='+d.size);
            if(d.ptr.isNull()||d.size===0||d.size>200000) return;
            var n=Math.min(d.size, 64);
            for(var i=0;i<n;i++){ try{ var e=d.ptr.add(i*8).readPointer();
                if(e.isNull()){ flog('    ['+i+'] <NULLPTR>'); continue; }
                var ty; try{ ty=e.readPointer(); }catch(x){ flog('    ['+i+'] p='+e+' <BADPTR>'); continue; }
                var pnm='?'; try{ pnm=nm(e.add(8).readU64()); }catch(x){}
                var fl='?'; try{ fl='0x'+e.add(0x28).readU64().toString(16); }catch(x){}
                flog('    ['+i+'] p='+e+' typeptr='+ty+' name='+pnm+' type='+(ty.isNull()?'<NULLTYPE>':typeName(ty))+' flags='+fl);
            }catch(x){ flog('    ['+i+'] <err '+x+'>'); } }
        }
        // Targeted capture of the two known crashing classes (by name-hash) so we can compare prop/type pointers
        // at collector-leave (props valid) vs dfb4 (types nulled) and find WHAT nulls them.
        var TARGETS = { '0x404d2a0f9a0c3989':'SoundBanksJson', '0xca1bb34ad933a066':'DynamicEntitySpec' };
        function clsHashHex(cls){ try{ var vt=cls.readPointer(); if(vt.isNull()) return null;
            var gn=new NativeFunction(vt.add(0x10).readPointer(),'uint64',['pointer']); return '0x'+gn(cls).toString(16); }catch(e){ return null; } }
        function dumpFull(where, cls){ flog('#### ['+where+'] '+nameHash(cls)+' ####');
            dumpArr('  props@0x28 ', cls, 0x28); dumpArr('  unk118     ', cls, 0x118); }
        function dumpParents(cls){ var n=cls, g=0; while(n && !n.isNull() && g<32){
            var par; try{ par=n.add(0x10).readPointer(); }catch(x){ break; }
            if(par.isNull()) { flog('  parent chain end at '+nameHash(n)); break; }
            flog('  parent: '+nameHash(par)); dumpArr('    parent props@0x28', par, 0x28);
            if(par.equals(n)) break; n=par; g++; } }
        // Drop null-pointer / null-type entries in a DynArray at (off, count@off+0xc). Returns #dropped.
        function compact(cls, off){ var d=darr(cls,off); if(!d||d.ptr.isNull()||d.size===0||d.size>200000) return 0;
            var w=0, dropped=0; for(var i=0;i<d.size;i++){ var e; try{ e=d.ptr.add(i*8).readPointer(); }catch(x){ dropped++; continue; }
                var drop=e.isNull(); if(!drop){ try{ if(e.readPointer().isNull()) drop=true; }catch(x){ drop=true; } }
                if(drop){ dropped++; continue; } if(w!==i) d.ptr.add(w*8).writePointer(e); w++; }
            if(dropped>0) cls.add(off+0xc).writeU32(w); return dropped; }
        var logCount = 0;
        // ============ RE-CAPACITY PRESERVE FIX (the root-cause repair, Ghidra-verified 2026-07-04) ============
        // FUN_1000286e8 (redContainers dynamicBuffer re-capacity) picks its allocator from a TRAILING HANDLE word
        // stored after the entries (buf + alignUp8(cap*elem)); default handle = &table@0x6e4aee8. The realloc
        // (handle fn +0x18 -> FUN_100022a84 -> FUN_10000ffac) sizes its preserve-copy by looking the OLD pointer
        // up in the ENGINE HEAP's own block registry - if that lookup fails the buffer comes back FRESH with
        // preserved=0 and 286e8 bzeroes it: silent data loss. Observed on our classes' finalize arrays: grow 1->2
        // nulled slot 0 (SoundBanksJson), shrink 13->12 nulled all 12 (DynamicEntitySpec). FIX: hook 286e8, but
        // ONLY for the four finalize arrays (cls+0x118 unk118, +0x128, +0x138, +0x148) of the class currently
        // inside FUN_10219e270/dce0/dfb4 (per-thread ctx). Save entries on enter (+ log the trailing handle:
        // default vs OTHER = the provenance answer); on leave, if the realloc zeroed them, write them back.
        var FIN_FNS = [0x219e270, 0x219dce0, 0x219dfb4];
        var finCtx = {};   // threadId -> {cls, depth}
        var g_lastFinAt = 0;   // Date.now() of the most recent finalize call (drives the auto-detach timer)
        function finEnter(tid, p){ g_lastFinAt = Date.now(); var c=finCtx[tid]; if(!c){ c={cls:null,depth:0}; finCtx[tid]=c; }
            if(c.depth===0){ c.cls = looksLikeClass(p) ? p : null; } c.depth++; }
        function finLeave(tid){ var c=finCtx[tid]; if(!c) return; c.depth--; if(c.depth<=0){ c.depth=0; c.cls=null; } }
        FIN_FNS.forEach(function(off){
            g_finalizeHookListeners.push(Interceptor.attach(base.add(off), {
                onEnter: function(a){ finEnter(this.threadId, a[0]); },
                onLeave: function(){ finLeave(this.threadId); }
            }));
        });
        var defHandle = base.add(0x6e4aee8);
        var recapLogs = 0, recapFixes = 0;
        g_finalizeHookListeners.push(Interceptor.attach(base.add(0x286e8), {
            onEnter: function(a){
                this.rec = null;
                var c = finCtx[this.threadId]; if(!c || !c.cls) return;
                var d = a[0], offv = -1;
                if(d.equals(c.cls.add(0x118))) offv=0x118;
                else if(d.equals(c.cls.add(0x128))) offv=0x128;
                else if(d.equals(c.cls.add(0x138))) offv=0x138;
                else if(d.equals(c.cls.add(0x148))) offv=0x148;
                if(offv<0) return;
                var buf = d.readPointer(), cap = d.add(8).readU32(), size = d.add(0xc).readU32();
                var newCap = a[1].toInt32(), elem = a[2].toInt32();
                if(size>100000 || newCap<0 || elem<=0 || elem>64) return;
                var rec = { d:d, cls:c.cls, off:offv, buf:buf, cap:cap, size:size, newCap:newCap, elem:elem, saved:null, keep:0, handle:null };
                if(!buf.isNull() && cap>0){ try{ rec.handle = buf.add((cap*elem+7)&~7).readPointer(); }catch(e){} }
                if(!buf.isNull() && size>0){
                    var keep = Math.min(size, newCap) * elem;
                    if(keep>0){ try{ rec.saved = buf.readByteArray(keep); rec.keep = keep; }catch(e){} }
                }
                this.rec = rec;
                if(recapLogs<200){
                    // PROVENANCE PROBE (first 12): which MODULE owns the allocator handle + its realloc fn?
                    // If Codeware.dylib -> our SDK Allocator<T> (the alloc-fix would work); if the main exe /
                    // Cyberpunk2077 -> an ENGINE allocator (the alloc-fix would NOT touch these arrays).
                    var prov = '';
                    if(recapLogs<12 && rec.handle && !rec.handle.isNull()){
                        var hmod='?', rmod='?';
                        try{ var m=Process.findModuleByAddress(rec.handle); hmod=m?m.name:'<none>'; }catch(e){}
                        try{ var vt=rec.handle.readPointer(); var rf=vt.add(0x18).readPointer(); var rm=Process.findModuleByAddress(rf); rmod=(rm?rm.name:'<none>')+'@'+rf; }catch(e){}
                        prov = ' handleMod=' + hmod + ' reallocFn=' + rmod;
                    }
                    flog('[RECAP] cls='+rec.cls+' off=0x'+offv.toString(16)+' buf='+buf+' cap='+cap+' size='+size
                        +' -> newCap='+newCap+' elem='+elem
                        +' handle='+(rec.handle ? (rec.handle+(rec.handle.equals(defHandle)?' (default)':' (OTHER!)')) : 'n/a') + prov);
                    recapLogs++;
                }
            },
            onLeave: function(){
                var rec = this.rec; if(!rec || !rec.saved) return;
                try{
                    var nb = rec.d.readPointer(); if(nb.isNull()) return;
                    var cur = new Uint8Array(nb.readByteArray(rec.keep));
                    var sav = new Uint8Array(rec.saved);
                    var same = true, allz = true;
                    for(var i=0;i<rec.keep;i++){ if(cur[i]!==sav[i]) same=false; if(cur[i]!==0) allz=false; }
                    if(!same){
                        if(allz){
                            nb.writeByteArray(rec.saved);
                            recapFixes++;
                            if(recapFixes<=200) flog('[RECAP-FIX #'+recapFixes+'] cls='+rec.cls+' off=0x'+rec.off.toString(16)
                                +' restored '+rec.keep+' bytes ('+rec.buf+' -> '+nb+')');
                        } else if(recapLogs<220){ flog('[RECAP-DIFF-NONZERO] cls='+rec.cls+' off=0x'+rec.off.toString(16)); recapLogs++; }
                    }
                }catch(e){ flog('[RECAP] leave err '+e); }
            }
        }));
        // ============ end re-capacity preserve fix (the ONLY hook needed for bug #1; RECAP-FIX did all 19
        // restores in the good run, collector/dfb4 below contributed 0 -> they are diagnostics, diag-gated) ====
        // Dump an overriddenProps-style array (16-byte pairs {prop@0, extra@8}, count in PAIRS at off+0xc).
        function dumpPairs(tag, cls, off){ var d=darr(cls,off); if(!d){ flog('  '+tag+' <no darr>'); return; }
            flog('  '+tag+' ptr='+d.ptr+' cap='+d.cap+' size(pairs)='+d.size);
            if(d.ptr.isNull()||d.size===0||d.size>200000) return;
            var n=Math.min(d.size,48);
            for(var i=0;i<n;i++){ try{ var e=d.ptr.add(i*16).readPointer();
                if(e.isNull()){ flog('    ['+i+'] prop=<NULL>'); continue; }
                var pnm='?'; try{ pnm=nm(e.add(8).readU64()); }catch(x){}
                var ty; try{ ty=e.readPointer(); }catch(x){ flog('    ['+i+'] prop='+e+' <BADPTR>'); continue; }
                flog('    ['+i+'] prop='+e+' name='+pnm+' type='+(ty.isNull()?'<NULLTYPE>':typeName(ty)));
            }catch(x){ flog('    ['+i+'] <err '+x+'>'); } }
        }
        // FUN_102197928 @0x2197928 = the collector. It RECURSES the parent chain (all levels share the SAME out
        // pointer = original class + 0x118) and memcpys each class's props@0x28 into out, with an override-
        // substitution pass. We hook its LEAVE and act ONLY on the OUTERMOST call (out == cls+0x118, i.e. this
        // level's class owns out) - at that point unk118 is fully built, and this fires BEFORE dce0's first walk.
        // If unk118 has a null-ptr/null-type entry, DUMP the class (props@0x28 + overriddenProps@0x38 + unk118) so
        // the source is identifiable, then COMPACT unk118 (fix size@0x124) so both walks survive. No looksLikeClass
        // gate (unk118 is stale at dce0 onEnter, which made the previous gate skip the culprit).
        // The collector + dfb4 hooks below contributed 0 fixes in the good run (RECAP does all the work); they are
        // DIAGNOSTIC-ONLY now, armed only under /tmp/cp2077_finaldiag so normal Codeware play skips them.
        if(diag){
        g_finalizeHookListeners.push(Interceptor.attach(base.add(0x2197928), {
            onEnter: function(a){ this.cls = a[0]; this.out = a[1]; },
            onLeave: function(){
                try{
                    var cls = this.cls, out = this.out;
                    if(cls.isNull() || out.isNull()) return;
                    if(!out.equals(cls.add(0x118))) return;              // outermost only
                    var th = clsHashHex(cls);
                    if(th && TARGETS[th] && logCount<80){ dumpFull('COLLECTOR-LEAVE', cls); dumpParents(cls); logCount++; }
                    var ptr = out.readPointer(); var size = out.add(0xc).readU32();
                    if(ptr.isNull() || size===0 || size>200000) return;
                    var w=0, dropped=0, reasons=[];
                    for(var i=0;i<size;i++){
                        var e; try{ e=ptr.add(i*8).readPointer(); }catch(x){ dropped++; if(reasons.length<12) reasons.push(i+':badslot'); continue; }
                        var drop=false, why='';
                        if(e.isNull()){ drop=true; why='NULLPTR'; }
                        else { var ty; try{ ty=e.readPointer(); }catch(x){ drop=true; why='BADPTR'; }
                               if(!drop && ty.isNull()){ drop=true; why='NULLTYPE'; } }
                        if(drop){ dropped++; if(reasons.length<12) reasons.push(i+':'+why); continue; }
                        if(w!==i) ptr.add(w*8).writePointer(e); w++;
                    }
                    if(dropped>0){
                        if(logCount<80){
                            flog('==== [COLLECTOR] class='+nameHash(cls)+' unk118 dropped='+dropped+' ['+reasons.join(',')+'] size '+size+'->'+w+' ====');
                            dumpArr('  props@0x28        ', cls, 0x28);
                            dumpPairs('  overriddenP@0x38 ', cls, 0x38);
                            dumpArr('  unk118 (pre-fix)  ', cls, 0x118);
                            logCount++;
                        }
                        out.add(0xc).writeU32(w);   // fix unk118 size before dce0 walks it
                    }
                }catch(e){ flog('[COLLECTOR] onLeave err '+e); }
            }
        }));
        // FUN_10219dfb4 @0x219dfb4 onEnter: belt-and-suspenders - compact unk118 (should already be clean). Do NOT
        // touch list@0x128 (sparse-by-design; compacting it misaligns the parallel serialization structures).
        g_finalizeHookListeners.push(Interceptor.attach(base.add(0x219dfb4), {
            onEnter: function(a){
                try{
                    var cls = a[0];
                    if(!looksLikeClass(cls)) return;
                    var th = clsHashHex(cls);
                    if(th && TARGETS[th] && logCount<80){ dumpFull('DFB4-ENTER', cls); logCount++; }
                    var d1 = compact(cls, 0x118);
                    if(d1>0 && logCount<160){ flog('[DFB4-BACKUP] class='+nameHash(cls)+' unk118 compacted='+d1); logCount++; }
                }catch(e){ flog('[DFB4] onEnter err '+e); }
            }
        }));
        }
        // AUTO-DETACH: FUN_1000286e8 is a hot path; keep the preserve hook only for the one-shot startup class
        // finalize. Poll: once finalize activity has been quiet for 5s (all our classes finalized, game at menu,
        // before any save-load), detach ALL preserve hooks so 286e8 runs natively -> zero save-load/gameplay cost.
        // Timer-based so it is robust to the finalize driver FUN_1021950fc being called in multiple batches
        // (detaching on a single driver onLeave fired too early and left #1 unfixed).
        var g_detachPoll = setInterval(function(){
            try {
                if(g_finalizeHooksDetached){ clearInterval(g_detachPoll); return; }
                if(g_lastFinAt > 0 && (Date.now() - g_lastFinAt) > 5000){
                    var n = g_detachFinalizeHooks();
                    flog('[FINAL] auto-detached '+n+' preserve hooks (finalize quiet 5s) -> native 286e8, no gameplay overhead');
                    clearInterval(g_detachPoll);
                }
            } catch(e){ flog('[FINAL] detach-poll err '+e); }
        }, 1000);
        flog('[FINAL-DIAG] armed finalize preserve fix (fix='+fix+' diag='+diag+', '+g_finalizeHookListeners.length+' hooks, auto-detach 5s after finalize settles)');
        // NOTE: do NOT Interceptor.attach FUN_10219721c (CClass teardown) or any function that runs on the
        // engine worker/redDispatcher threads - the macOS-27 frida-gum trampoline is broken on those threads
        // (SIGBUS in the trampoline before onEnter runs; confirmed 2026-07-05). Bug #2 (worker-thread async
        // teardown of a corrupt-listeners CClass) must be addressed on the MAIN thread (at the destroy-job
        // enqueue / the listeners write) or in C++, never by hooking the worker-thread teardown itself.
    } catch(e){ flog('[FINAL-DIAG] install err '+e); }
})();

// ===== VIRTUAL ATELIER SPAWN-PATH PROBE (2026-07-13) =====
// Diagnostic tracing of the ink widget-library spawn chain around Codeware's WidgetSpawningService fix.
// IMPORTANT OWNERSHIP RULE: the 4 spawn CORES (SpawnFromLocal 0x4965de0, SpawnFromExternal 0x4965ec0,
// AsyncSpawnFromLocal 0x4965980, AsyncSpawnFromExternal 0x4965b38) are owned by RED4ext MANUAL INLINE
// HOOKS (Codeware WidgetSpawningService, armed via RED4EXT_GUM_HOOK_OFFSETS) - a Frida attach there would
// patch over the detour branch and destroy it. This probe therefore hooks ONLY the un-owned inner
// functions, which still discriminate everything:
//   ResolveExternalLibrary 0x4965c90  (x8=out lib-Handle* SRET, x0=registry, x1=pathHash; on miss *out=0, NO load, NO log)
//        -> a NON-NULL resolve for a VA pathHash proves Codeware's InjectDependency worked (THE fix signal)
//   InstantiateItem        0x4923164  (x8=out SRET, x0=itemEntry w/ CName@+0 - logs BOTH x0/x1 u64s defensively)
//        -> fires once per successful item lookup (page spawns + every grid row)
//   HasExternalLibrary     0x4966554  (arg map unverified; x1 logged with path labeling, w0 retval)
// Codeware-side actions (injection, colon-retry) are logged by the plugin itself to its red4ext log.
// x8 is NOT in Frida's args[] - read it via this.context.x8 in onEnter.
// Item names are logged as raw u64 CName hashes.
// Gated on /tmp/cp2077_vaspawn_probe (NOT in nctool Regen's flag-restore set - re-touch per boot).
// Appends to /tmp/cp2077_vaspawn.log with ISO timestamps. Rate-capped: first 400 events per hook,
// then 1-in-50 sampling, so SpawnFromLocal cannot flood the log or tank frame time on IO.
(function installSpawnProbe(){
    var LOG='/tmp/cp2077_vaspawn.log';
    function ts(){ try{ return new Date().toISOString(); }catch(e){ return '?'; } }
    function vlog(s){ try{ var f=new File(LOG,'a'); f.write(ts()+' '+s+'\n'); f.flush(); f.close(); }catch(e){} try{ console.log('[VASPAWN] '+s); }catch(e2){} }
    try {
        var on=false; try{ File.readAllText('/tmp/cp2077_vaspawn_probe'); on=true; }catch(e){}
        if(!on) return;
        var base; try{ base=getModuleBase(); }catch(e){ base=null; }
        if(!base){ vlog('[VASPAWN] ERROR: no module base'); return; }
        vlog('=== spawn probe session start (base '+base+') ===');
        // Known widget-library resource pathHashes (VA + inkWidgets), labeled inline when they match.
        // Keys = NativePointer.toString() form (0x-prefixed, lowercase, NO leading zeros).
        var PATHS = {
            '0x5a413ee04843c418': 'stores',
            '0xce44de04cd1368a9': 'virtual_atelier',
            '0xd6b2a2bceeee5160': 'buttonhints',
            '0xae393b6200c959af': 'slots',
            '0xe655e42677452363': 'va_slots',
            '0xd673c2bbd086462':  'preview'
        };
        function pathLabel(p){ try{ var h=p.toString(); var l=PATHS[h]; return l?(h+'<'+l+'>'):h; }catch(e){ return '<e>'; } }
        // Per-hook rate cap: log the first 400 events, then 1 in 50 (returns the event # to log, or 0 to skip).
        var caps={};
        function gate(key){ var c=caps[key]=(caps[key]||0)+1;
            if(c===401) vlog('[CAP] '+key+' hit 400 events -> sampling 1-in-50 from here');
            if(c<=400) return c;
            return (c%50===0)?c:0; }
        // Deref an out-Handle slot saved at onEnter (Handle ptr at +0).
        function derefOut(p){ try{ if(!p||p.isNull()) return 'out=<null>'; var v=p.readPointer(); return v.isNull()?'=> NULL':('=> '+v); }catch(e){ return '=> <unreadable>'; } }
        // Read a u64 at p+0 defensively (for itemEntry CName sniffing).
        function u64at(p){ try{ if(p&&!p.isNull()) return '0x'+p.readU64().toString(16); }catch(e){} return '<unreadable>'; }
        // --- ResolveExternalLibrary 0x4965c90 (x8=out SRET, x0=registry, x1=pathHash) ---
        try {
            Interceptor.attach(base.add(0x4965c90), {
                onEnter: function(a){ this.n=gate('RESOLVE'); if(!this.n) return; this.out=this.context.x8; this.ph=pathLabel(a[1]); },
                onLeave: function(){ if(!this.n) return; var d=derefOut(this.out); vlog('[RESOLVE #'+this.n+'] path='+this.ph+' '+d+(d==='=> NULL'?' (MISS: engine does NO load, NO log)':'')); }
            });
            vlog('hook OK ResolveExternalLibrary @+0x4965c90');
        } catch(e){ vlog('[VASPAWN] hook FAIL ResolveExternalLibrary @+0x4965c90: '+e); }
        // --- spawn CORES: NOT hooked (owned by Codeware's RED4ext manual inline hooks - see banner) ---
        // --- InstantiateItem 0x4923164 (Ghidra-confirmed x8=out SRET, x0=itemEntry w/ CName u64 @ +0;
        //     u64@x1 logged too as a cheap self-check) ---
        try {
            Interceptor.attach(base.add(0x4923164), {
                onEnter: function(a){ this.n=gate('INST-ITEM'); if(!this.n) return; this.out=this.context.x8;
                    this.e0=u64at(a[0]); this.e1=u64at(a[1]); },
                onLeave: function(){ if(!this.n) return; vlog('[INST-ITEM #'+this.n+'] u64@x0='+this.e0+' u64@x1='+this.e1+' '+derefOut(this.out)); }
            });
            vlog('hook OK InstantiateItem @+0x4923164');
        } catch(e){ vlog('[VASPAWN] hook FAIL InstantiateItem @+0x4923164: '+e); }
        // --- HasExternalLibrary 0x4966554 ---
        try {
            Interceptor.attach(base.add(0x4966554), {
                onEnter: function(a){ this.n=gate('HAS-EXT'); if(!this.n) return; this.a1=pathLabel(a[1]); this.a2=a[2].toString(); },
                onLeave: function(r){ if(!this.n) return; vlog('[HAS-EXT #'+this.n+'] x1='+this.a1+' x2='+this.a2+' ret(w0)='+r.toString()); }
            });
            vlog('hook OK HasExternalLibrary @+0x4966554');
        } catch(e){ vlog('[VASPAWN] hook FAIL HasExternalLibrary @+0x4966554: '+e); }
        vlog('=== spawn probe armed ('+Object.keys(caps).length+' counters live at first event) ===');
    } catch(e){ vlog('[VASPAWN] install err '+e); }
})();
