/**
 * RED4ext Hooks for macOS - Frida Gadget Implementation (v7-lean)
 *
 * v7: perf pass. Removed the legacy logging-only interceptors (Main, ExecuteProcess,
 * Validate, CollectSaveableSystems, ... — 9 hooks that did nothing but log), the
 * cybermodman loc-name fill hook (its config path pointed at another machine and never
 * loaded, yet the hook sat on the hot localized-string lookup), and all DIAG hooks.
 * The MINI-CET capture hooks now auto-detach once essentials are captured ('recap'
 * re-arms), and the command trampoline only attaches while a command is pending, so
 * steady-state gameplay runs with ZERO Frida hooks on the script-VM hot path.
 */

'use strict';

let moduleBase = null;
function getModuleBase() {
    if (moduleBase !== null) return moduleBase;
    const modules = Process.enumerateModules();
    for (const mod of modules) {
        if (mod.name.includes('Cyberpunk2077')) { moduleBase = mod.base; return moduleBase; }
    }
    if (modules.length > 0) { moduleBase = modules[0].base; return moduleBase; }
    return null;
}
// ============================================================================
// CP2077SaveKit MINI-CET v7-lean -- universal RTTI call + enums + chains.
//   give <Items.NAME> <qty> | money <amt> | call <Class> <method> [args] | perks <n> | attrs <n> | relic <n>
//   sc <n> | level <n> | godmode | invis | infammo | heal | time | slowmo | nopolice | tp | summon | setfact
//   recap (re-arm capture hooks after a save load) | debug on/off (diagnostic logging) | mapscan | sig | findinst
// Resolves ANY method via CClass.funcs (+0x48), walks parents; live instance per class; enum args by name.
// ============================================================================
(function () {
    const OUT='/tmp/cp2077_out.txt', CMD='/tmp/cp2077_cmd.txt';
    function log(s){ try{const f=new File(OUT,'a');f.write(s+'\n');f.flush();f.close();}catch(e){} try{console.log('[MINICET] '+s);}catch(e2){} }
    let DBG=false;                                   // v7: diagnostic logging off by default ('debug on' to enable)
    function dbg(s){ if(DBG) log(s); }
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
        const base=getModuleBase();
        const execAddr=base.add(0x27b9c88);  // drain hook point (fires on every script call)
        // Fault forensics: zero steady-state cost (fires only on a crash), invaluable when one happens.
        let _faultLogged=0;
        Process.setExceptionHandler(function(d){
            if(_faultLogged>=2) return false; _faultLogged++;
            try{ const pc=d.context.pc;
                log('FAULT '+d.type+' addr='+d.address+' pc='+pc+' off=0x'+pc.sub(base).toString(16)+
                    ' lr='+d.context.lr+' lr_off=0x'+d.context.lr.sub(base).toString(16));
                let s=''; for(let i=0;i<=28;i++){ s+='x'+i+'='+d.context['x'+i]+' '; } log('REGS '+s);
            }catch(e){ log('FAULT handler err '+e); }
            return false;   // log then let it die; relaunch anyway
        });
        // GOG: FUN_1027ba1b4 is the 5-arg universal caller (branches native vs scripted on fn+0xa8).
        const Exec=new NativeFunction(base.add(0x27ba1b4),'uint64',['pointer','pointer','pointer','pointer','pointer']);
        let reg=null,GetClass=null,GetEnum=null;
        function ensureReg(){ if(reg) return; reg=new NativeFunction(base.add(0x26ae7a4),'pointer',[])(); const rv=reg.readPointer();
            GetClass=new NativeFunction(rv.add(0x10).readPointer(),'pointer',['pointer','uint64']);
            GetEnum =new NativeFunction(rv.add(0x18).readPointer(),'pointer',['pointer','uint64']); }
        let player=null, playerVt=null, fromtd=null, depth=0, busy=false, lastCmd=''; const pendingQ=[];
        const playerCands=[], playerCandSet=new Set(); let devOwner=null;  // cached dev-data owner (the local player)
        function addCand(ctx){ const k=ctx.toString(); if(playerCandSet.has(k)) return; playerCandSet.add(k); playerCands.push(ctx); if(playerCands.length>8){ const old=playerCands.shift(); playerCandSet.delete(old.toString()); } }
        const instReg={}, seenVt=new Set(); let nameHookInstalled=false;
        const clsByHash={};   // CName-hash(hex string) -> CClass meta, built from the capture hook (GOG RTTI GetClass is non-virtual; capture gives us the same metas)
        const clsVals=new Set(), seenClsP=new Set(); let _parentOff=-1; const _parentDetect={};
        function regCls(meta){ try{ const nm=nameOf(meta); if(nm){ clsByHash[nm]=meta; clsVals.add(meta.toString()); } return nm; }catch(e){ return null; } }
        const refcnt=Memory.alloc(8); refcnt.writeU32(0x100000); refcnt.add(4).writeU32(0x100000);
        function nameOf(metaObj){ try{ const gn=metaObj.readPointer().add(0x10).readPointer(); return '0x'+new NativeFunction(gn,'uint64',['pointer'])(metaObj).toString(16);}catch(e){return null;} }
        function sigStr(fn){ try{ const pe=fn.add(0x28).readPointer(), pc=fn.add(0x30).readU32(); let p=[]; for(let i=0;i<pc;i++){ p.push(nameOf(pe.add(i*8).readPointer().readPointer())); } return 'params['+pc+']=['+p.join(',')+']'; }catch(e){ return 'sigErr'; } }
        // ===== DIAG: auto-discover the real GetClass vtable slot (root cause = this call faults at 0x8) =====
        // GOG: the RTTI system is non-virtual, so Steam's `(*reg)[GetClass](reg,hash)` faults.
        // Instead resolve class metas from the capture hook's clsByHash map (same CClass objects).
        let _clsMiss=0, _mapscanned=false;
        function clsByName(n){ const h='0x'+u64(fnv(n)).toString(16); let m=clsByHash[h];
            if(!m && !_mapscanned){ _mapscanned=true; dbg('clsByName: "'+n+'" miss -> enumerating ALL classes via RTTI type table'); try{ mapscan(); }catch(e){ log('mapscan threw '+e); } m=clsByHash[h]; }
            if(!m && _clsMiss<40){ _clsMiss++; dbg('clsByName MISS "'+n+'" ('+h+')'); }
            return m||null; }
        // UNIVERSAL class resolution: the RTTI system holds its types in sorted arrays (binary-searched by
        // FUN_10264e238). Rather than depend on runtime capture (which never sees native-only system classes
        // like PlayerDevelopmentSystem / TeleportationFacilitySystem), walk the system's type array directly
        // and register EVERY class by name. Located + validated against the classes capture already proved.
        // inMod(p): true if p lies inside ANY loaded module image (not just base's module — on macOS the
        // engine metas may live in a separate dylib). This is the crash-safe gate before the native nameOf()
        // call: GetName() on a sane-but-fake vtable is a segfault try/catch cannot trap; a pointer not inside
        // any mapped module is garbage -> skipped. Module ranges enumerated once and cached.
        let _modRanges=null;
        function modRanges(){ if(_modRanges) return _modRanges; _modRanges=[];
            try{ for(const m of Process.enumerateModules()){ _modRanges.push([m.base, m.base.add(m.size)]); } }catch(e){}
            return _modRanges; }
        function inMod(p){ try{ const rs=modRanges(); for(let i=0;i<rs.length;i++){ if(p.compare(rs[i][0])>=0 && p.compare(rs[i][1])<0) return true; } return false; }catch(e){ return false; } }
        // Ground-truth array finder: capture already proved 419 real meta pointers (clsVals). Any field of the
        // RTTI singleton whose ELEMENTS intersect that set IS the type array — no count guess, no nameOf, no
        // inMod, pure crash-safe pointer reads. Probes the field directly AND one level deeper (the lookup
        // decompile's map is a heap sub-struct the singleton points to, not an inline array), across the three
        // plausible (stride,valueOffset) layouts. Returns {baseP,stride,vo,indir} or null.
        // Build the full ground-truth set of known meta pointers from clsByHash VALUES (capture path at line
        // 1164 writes clsByHash directly and never touches clsVals, so clsVals is only a subset).
        function gtMetaSet(){ const s=new Set(); for(const k in clsByHash){ try{ const v=clsByHash[k]; if(v) s.add(v.toString()); }catch(e){} } for(const v of clsVals) s.add(v); return s; }
        // Returns ALL fields whose elements intersect the ground-truth meta set (not just the best), so the
        // union walk below can cover whichever field is the real master registry.
        function findTypeArrays(gt){
            const cands=[];
            for(let off=0; off<=0x168; off+=8){ let P; try{ P=reg.add(off).readPointer(); }catch(e){ continue; }
                let Q=null; try{ Q=P.readPointer(); }catch(e){}
                for(const [baseP,indir] of [[P,false],[Q,true]]){ if(!baseP||!sane(baseP)) continue;
                    for(const [stride,vo] of [[8,0],[16,0],[16,8]]){ let hits=0;
                        try{ for(let i=0;i<2048;i++){ const m=baseP.add(i*stride+vo).readPointer(); if(gt.has(m.toString())){ if(++hits>=3) break; } } }catch(e){}
                        if(hits){ dbg('  GTHIT off=0x'+off.toString(16)+(indir?' indir':' direct')+' stride='+stride+' vo='+vo+' gtHits='+hits+' baseP='+baseP);
                            cands.push({off:off,baseP:baseP,stride:stride,vo:vo,indir:indir,gt:hits}); } } } }
            return cands; }
        function mapscan(){ ensureReg(); if(!reg){ dbg('mapscan: no reg'); return false; }
            const gt=gtMetaSet();
            dbg('mapscan: reg='+reg+' known-before='+Object.keys(clsByHash).length+' groundTruthMetaPtrs='+gt.size);
            try{ const M=Process.findModuleByAddress(base);
                dbg('  MODCHK base='+base+' mod='+(M?M.name:'?')+' size='+(M?'0x'+M.size.toString(16):'?')+' nLoadedModules='+modRanges().length); }catch(e){ dbg('  MODCHK err '+e); }
            // GATE: nameOf() calls meta->[0]->[0x10] (GetName). The first qword (meta->[0]) is PER-CLASS (~1:1 with
            // classes, so useless as a gate), but the GetName fn pointer meta->[0]->[0x10] is SHARED across all class
            // descriptors (one CClass::GetName). Gating on the set of GetName fn ptrs we already called during capture
            // lets PlayerDevelopmentSystem (own first-qword, same GetName) through, and is crash-safe by construction
            // (we only ever call a fn pointer we have already called).
            const knownGN=new Set();
            for(const k in clsByHash){ try{ const v=clsByHash[k]; if(v){ const gn=v.readPointer().add(0x10).readPointer(); if(sane(gn)) knownGN.add(gn.toString()); } }catch(e){} }
            dbg('  knownGN='+knownGN.size+' (expect small: ~1 = one CClass::GetName)');
            const theGN = knownGN.size ? ptr([...knownGN][0]) : null;
            // density(baseP,stride,vo): how many of the first N entries are class metas (GetName ptr == theGN).
            // Layout-agnostic — finds the MASTER registry even if its early entries contain no CAPTURED meta.
            function density(baseP,stride,vo,N){ let d=0; try{ for(let i=0;i<N;i++){ const m=baseP.add(i*stride+vo).readPointer(); if(!sane(m)) continue;
                let g; try{ g=m.readPointer().add(0x10).readPointer(); }catch(e){ continue; } if(theGN&&g.equals(theGN)) d++; } }catch(e){} return d; }
            // FULL FIELD DUMP + density per field (find the biggest type array, named or not)
            dbg('  --- singleton field dump (density = #class-metas in first 2048 @stride8) ---');
            const cands=[]; const seen=new Set();
            for(let off=0; off<=0x168; off+=8){ let P; try{ P=reg.add(off).readPointer(); }catch(e){ continue; }
                let Q=null; try{ Q=P.readPointer(); }catch(e){}
                const d8 = sane(P)?density(P,8,0,2048):0;
                dbg('   field +0x'+off.toString(16)+' = '+P+' u32@8='+(()=>{try{return reg.add(off+8).readU32();}catch(e){return '-';}})()+' u32@c='+(()=>{try{return reg.add(off+0xc).readU32();}catch(e){return '-';}})()+' gnDensity='+d8);
                for(const [baseP,indir] of [[P,false],[Q,true]]){ if(!baseP||!sane(baseP)) continue;
                    for(const [stride,vo] of [[8,0],[16,8]]){ const d=density(baseP,stride,vo,2048);
                        if(d>=8){ const key=baseP.toString()+':'+stride+':'+vo; if(!seen.has(key)){ seen.add(key); cands.push({off:off,baseP:baseP,stride:stride,vo:vo,indir:indir,d:d}); } } } } }
            dbg('  --- '+cands.length+' type-array candidates (gnDensity>=8) ---');
            // Union-register from every candidate, knownGN-gated.
            let grand=0;
            for(const a of cands){ let total=0;
                for(let i=0;i<262144;i++){ let m; try{ m=a.baseP.add(i*a.stride+a.vo).readPointer(); }catch(e){ break; }
                    if(!sane(m)) continue;
                    let gn; try{ const vt=m.readPointer(); if(!sane(vt)) continue; gn=vt.add(0x10).readPointer(); }catch(e){ continue; }
                    if(!sane(gn)||!knownGN.has(gn.toString())) continue;
                    if(regCls(m)) total++; }
                dbg('  array off=0x'+a.off.toString(16)+(a.indir?' indir':' direct')+' stride='+a.stride+' vo='+a.vo+' d='+a.d+' -> registered '+total);
                grand+=total; }
            dbg('mapscan: registered '+grand+' class metas total; clsByHash now '+Object.keys(clsByHash).length+' classes');
            // per-link diagnostic: did the perks-critical class land — under ANY of its plausible RTTI names?
            for(const tn of ['PlayerDevelopmentSystem','gamePlayerDevelopmentSystem','cpPlayerDevelopmentSystem',
                             'PlayerDevelopmentData','gamePlayerDevelopmentData','cpPlayerDevelopmentData',
                             'gameTeleportationFacilitySystem','gameScriptableSystemsContainer']){
                dbg('  mapscan check '+tn+' -> '+(clsByHash['0x'+u64(fnv(tn)).toString(16)]?'REGISTERED':'absent')); }
            return Object.keys(clsByHash).length>gt.size; }
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
        // enum member value by enum-type-name-hash + member name
        function resolveEnumByTypeHash(typeHashHex, member){ ensureReg(); const en=GetEnum(reg,uint64(typeHashHex)); if(en.isNull()) return null;
            const hp=en.add(0x28).readPointer(), n=en.add(0x30).readU32(), vp=en.add(0x38).readPointer(); const mh=fnv(member);
            for(let i=0;i<n;i++){ if(hp.add(i*8).readU64().equals(u64(mh))) return vp.add(i*8).readU64(); } return null; }
        function fromTDBID(tb,out){ if(!fromtd) throw 'fromtd (TDBID->ItemID) not captured yet; open inventory / wait a moment, then retry';
            const bc=Memory.alloc(32);let o=0;bc.writeU8(0x11);o++;for(let i=0;i<8;i++){bc.add(o).writeU8(tb[i]);o++;}bc.add(o).writeU8(0x27);
            const fr=Memory.alloc(0x90);fr.writePointer(bc);fr.add(0x08).writePointer(fromtd.fn);fr.add(0x40).writePointer(fromtd.ctx?fromtd.ctx:ptr(0));return Exec(fromtd.fn,fromtd.ctx,fr,out,fromtd.retType); }
        // Resolve an enum member value DIRECTLY from the param-type meta callFunc already holds (ptype).
        // No virtual GetEnum (broken on GOG: RTTI is non-virtual) and no mapscan/clsByHash dependency.
        // Same enum-meta layout assumption as resolveEnumByTypeHash (+0x28 hashes, +0x30 count, +0x38 values).
        function enumVal(en, member){ if(!en||en.isNull()) return null;
            try{ const hp=en.add(0x28).readPointer(), n=en.add(0x30).readU32(), vp=en.add(0x38).readPointer(), mh=fnv(member);
                if(n>4096||!sane(hp)||!sane(vp)) return null;
                for(let i=0;i<n;i++){ if(hp.add(i*8).readU64().equals(u64(mh))) return vp.add(i*8).readU64(); } }catch(e){}
            return null; }
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
                else { let ev=enumVal(ptype, a); if(ev===null && /^-?\d+$/.test(a)) ev=uint64(parseInt(a));   // resolve enum off ptype (no virtual GetEnum)
                    if(ev!==null){ dst.writeU64(ev); log('  enum arg '+tn+' "'+a+'" -> 0x'+ev.toString(16)); } else throw 'unsupported enum '+tn+' member "'+a+'" (enumVal miss; ptype='+ptype+')'; }
                const cp=Memory.alloc(0x30); cp.writePointer(ptype); cp.add(0x20).writeU32(off); props.push(cp); }
            const bc=Memory.alloc(16+args.length*9); let o=0; for(let i=0;i<args.length;i++){ bc.add(o).writeU8(0x18);o++; bc.add(o).writePointer(props[i]);o+=8; } bc.add(o).writeU8(0x27);
            const fr=Memory.alloc(0x90); fr.writePointer(bc); fr.add(0x08).writePointer(fn); fr.add(0x10).writePointer(locals); fr.add(0x18).writePointer(locals); fr.add(0x40).writePointer(ctx.isNull?(ctx):ctx);
            const res=Memory.alloc(16); res.writeU64(0); res.add(8).writeU64(0); Exec(fn, ctx, fr, res, retType); return res; }
        function instOf(className){ const m=clsByName(className); if(!m) return null; const fv=m.sub(base).add(FV0).toString(16); return instReg[fv]||null; }
        // v6: register a class meta + instance FROM a live object (same vt+8 GetType call the capture
        // hook makes at the exec-body hook — proven to return the SCRIPT class for scripted instances,
        // e.g. EquipmentSystem). This is the only way to get metas for scripted classes: they are not in
        // the RTTI arrays mapscan walks, and the capture hooks' seenVt dedup means only the FIRST
        // scripted system (they all share the native base vtable) ever gets captured. aliasName also
        // maps the requested name to the meta in case the class's true CName differs.
        function regFromInstance(inst, aliasName){ try{ const vt=inst.readPointer(); if(!sane(vt)) return null;
            const gt=vt.add(8).readPointer(); if(!sane(gt)) return null;
            const meta=new NativeFunction(gt,'pointer',['pointer'])(inst); if(!meta||meta.isNull()||!sane(meta)) return null;
            const nm=regCls(meta); instReg[meta.sub(base).add(FV0).toString(16)]=inst;
            if(aliasName){ const ah='0x'+u64(fnv(aliasName)).toString(16); if(!clsByHash[ah]) clsByHash[ah]=meta; }
            return nm; }catch(e){ return null; } }
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
            const bc=Memory.alloc(16+items.length*9); let o=0; for(let i=0;i<items.length;i++){ bc.add(o).writeU8(0x18);o++; bc.add(o).writePointer(props[i]);o+=8; } bc.add(o).writeU8(0x27);
            const fr=Memory.alloc(0x90); fr.writePointer(bc); fr.add(0x08).writePointer(fn); fr.add(0x10).writePointer(locals); fr.add(0x18).writePointer(locals); fr.add(0x40).writePointer(ctx);
            const res=Memory.alloc(16); res.writeU64(0); res.add(8).writeU64(0); Exec(fn, ctx, fr, res, retType); return res; }
        function sane(pp){ try{ return !pp.isNull() && pp.compare(ptr('0x10000'))>0 && pp.compare(ptr('0x800000000000'))<0; }catch(e){ return false; } }
        function getSystem(giBuf, className){    // giBuf = GetGame result buffer (a GameInstance wrapper)
            const cls=clsByName(className); if(!cls){ dbg('  class '+className+' not found'); return null; }
            for(const goff of [8, 0]){           // gameInstance ptr lives at wrapper+8 (per game's own code); fallback +0
                try{
                    const gi=giBuf.add(goff).readPointer(); if(!sane(gi)) continue;
                    const holder=gi.add(0x48).readPointer(); if(!sane(holder)) continue;
                    const cpp=holder.add(0xc0).readPointer(); if(!sane(cpp)) continue;
                    const container=cpp.readPointer(); if(!sane(container)) continue;
                    const cvt=container.readPointer(); if(!sane(cvt)) continue;
                    const getFn=new NativeFunction(cvt.add(0x10).readPointer(),'pointer',['pointer','pointer']);
                    const sys=getFn(container, cls); dbg('  getSystem('+className+') gi(+'+goff+')='+gi+' container='+container+' -> '+sys);
                    if(!sys.isNull()) return sys;
                }catch(e){ dbg('  getSystem gi+'+goff+' err: '+e); }
            }
            return null;
        }
        function resolveAny(classNames, method){ for(const c of classNames){ const e=resolveFunc(c,method); if(e){ e.cls=c; return e; } } return null; }
        // Get a scriptable system the way the VM does: GameInstance.GetScriptableSystemsContainer(gi).Get(name)
        function getScriptableSystem(giRes, sysName){
            // GOG: GameInstance/ScriptGameInstance classes aren't capturable (never an instance ctx),
            // so the static getter chain fails. But the system's own instance IS captured at ba1b4 -> use it.
            const cached=instOf(sysName); if(sane(cached)){ dbg('  '+sysName+' via captured instance '+cached); return cached; }
            try{ const viaC=getSystem(giRes, sysName); if(sane(viaC)){ dbg('  '+sysName+' via container walk '+viaC); return viaC; } }catch(e){}
            // v6: scripted systems (PlayerDevelopmentSystem...) have no class meta until we hold an
            // instance, but the scriptable-systems-container INSTANCE is captured at runtime — ask it
            // directly (confirmed live: container.Get('PlayerDevelopmentSystem') returns the system),
            // then register the returned object's class so resolveFunc() on the class works afterwards.
            try{ const cont2=instOf('gameScriptableSystemsContainer')||instOf('ScriptableSystemsContainer');
                const get2=cont2?resolveAny(['gameScriptableSystemsContainer','ScriptableSystemsContainer'],'Get'):null;
                if(cont2&&get2){ const r2=callFunc(get2.fn, cont2, get2.retType, [sysName]); const sys2=r2.readPointer();
                    if(sane(sys2)){ const nm2=regFromInstance(sys2, sysName); dbg('  '+sysName+' via captured container.Get '+sys2+' (class '+nm2+')'); return sys2; }
                    dbg('  container.Get('+sysName+') returned null'); }
                else if(!cont2) dbg('  container.Get skip: gameScriptableSystemsContainer not captured yet (play/open a menu a moment, then retry)');
            }catch(e){ dbg('  container.Get err: '+e); }
            const gsc=resolveAny(['GameInstance','ScriptGameInstance','gameScriptGameInstance'],'GetScriptableSystemsContainer');
            if(!gsc){ dbg('  GetScriptableSystemsContainer not found'); return null; }
            dbg('  GSC ['+gsc.cls+(gsc.isStatic?' static':' inst')+'] '+sigStr(gsc.fn));
            let cont=null;
            for(const nb of [8,16]){ try{ const r=callFunc(gsc.fn, player, gsc.retType, [{raw:giRes,n:nb}]);
                const c=r.readPointer(); dbg('  container(gi'+nb+')='+c); if(sane(c)){ cont=c; break; } }catch(e){ dbg('  GSC(gi'+nb+') err: '+e); } }
            if(!cont) return null;
            const get=resolveAny(['ScriptableSystemsContainer','gameScriptableSystemsContainer'],'Get');
            if(!get){ dbg('  container.Get not found'); return null; }
            dbg('  Get ['+get.cls+'] '+sigStr(get.fn));
            try{ const r=callFunc(get.fn, cont, get.retType, [sysName]); const sys=r.readPointer(); dbg('  '+sysName+' inst='+sys); return sane(sys)?sys:null; }
            catch(e){ dbg('  Get err: '+e); return null; }
        }
        // The owner the dev-data is keyed to is the local player puppet (one of several captured puppets
        // share its vtable). We can't pull it from the scriptable container (PlayerSystem isn't there),
        // so we probe owner candidates against GetDevelopmentData and cache the one that yields data.
        function getDevData(){
            const gg=resolveFunc('PlayerPuppet','GetGame'); if(!gg){ dbg('GetGame not found'); return null; }
            const giRes=callFunc(gg.fn, player, gg.retType, []);
            const sys=getScriptableSystem(giRes,'PlayerDevelopmentSystem');
            if(!sys){ dbg('could not get PlayerDevelopmentSystem instance'); return null; }
            const gdd=resolveFunc('PlayerDevelopmentSystem','GetDevelopmentData'); if(!gdd){ dbg('GetDevelopmentData not found'); return null; }
            const owners=[]; const ap=authPlayer(giRes); if(ap) owners.push(ap);   // authoritative local player first
            if(devOwner) owners.push(devOwner); if(player) owners.push(player); for(const c of playerCands) owners.push(c);
            const tried=new Set();
            for(const o of owners){ const k=o.toString(); if(tried.has(k)) continue; tried.add(k);
                try{ const r=callFunc(gdd.fn, sys, gdd.retType, ['@'+o]); const d=r.readPointer();
                    if(sane(d)){ devOwner=o; regFromInstance(d,'PlayerDevelopmentData');   // v6: scripted class — meta only reachable via a live instance
                        dbg('  devData='+d+' (owner '+o+', tried '+tried.size+')'); return d; } }
                catch(e){ dbg('  GetDevelopmentData('+o+') err: '+e); } }
            devOwner=null; dbg('  GetDevelopmentData: no owner of '+tried.size+' yielded data'); return null;
        }
        // ---- convenience-command helpers ----
        function getGI(){ const gg=resolveFunc('PlayerPuppet','GetGame'); if(!gg) return null; return callFunc(gg.fn, player, gg.retType, []); }
        function curPlayer(){ return devOwner||player; }
        // authoritative, deterministic local player (cpPlayerSystem.GetLocalPlayerControlledGameObject); falls back to captured
        function authPlayer(gi){ try{ gi=gi||getGI(); if(gi){ const p=getPlayerViaSystem(gi); if(p) return p; } }catch(e){} return curPlayer(); }
        // call a static GameInstance.<getter>(gi) -> system/facility ptr (same pattern as GetScriptableSystemsContainer)
        function getViaGetter(giRes, getterName){
            // GOG fallback: derive the system class from the getter name and use its captured instance.
            const baseN=getterName.replace(/^Get/,'').replace(/System$/,'');
            for(const cn of ['game'+baseN+'System', baseN+'System', 'cp'+baseN+'System']){
                const c=instOf(cn); if(sane(c)){ dbg('  '+getterName+' via captured '+cn+' '+c); return c; }
                try{ const cw=getSystem(giRes, cn); if(sane(cw)){ dbg('  '+getterName+' via container '+cn+' '+cw); return cw; } }catch(e){}
            }
            const g=resolveAny(['ScriptGameInstance','GameInstance','gameScriptGameInstance'], getterName);
            if(!g){ dbg('  getter '+getterName+' not found'); return null; }
            dbg('  '+getterName+' '+(g.isStatic?'[static]':'[inst]')+' '+sigStr(g.fn));
            for(const nb of [8,16]){ try{ const r=callFunc(g.fn, player, g.retType, [{raw:giRes,n:nb}]); const p=r.readPointer(); if(sane(p)) return p; }catch(e){ dbg('  '+getterName+'(gi'+nb+') err: '+e); } }
            return null;
        }
        // Authoritative local player via GameInstance.GetPlayerSystem(gi).<localPlayerGetter>() (probes the name).
        let _pgetter=null;
        function getPlayerViaSystem(gi){
            const ps=getViaGetter(gi,'GetPlayerSystem'); if(!ps){ dbg('  GetPlayerSystem not reachable'); return null; }
            const names=_pgetter?[_pgetter]:['GetLocalPlayerControlledGameObject','GetLocalPlayerMainGameObject','GetLocalPlayer','GetPlayerControlledGameObject','GetPlayer'];
            for(const cls of ['gamePlayerSystem','cpPlayerSystem','PlayerSystem']){
                for(const mn of names){ const m=resolveFunc(cls,mn); if(!m) continue;
                    try{ const r=callFunc(m.fn, ps, m.retType, []); const o=r.readPointer(); dbg('  '+cls+'.'+mn+' -> '+o); if(sane(o)){ _pgetter=mn; return o; } }
                    catch(e){ dbg('  '+cls+'.'+mn+' err '+e); } }
            }
            dbg('  no local-player getter resolved on the player system'); return null;
        }
        // godmode via the IsInvulnerable STAT (not the god-mode system). The damage pipeline's
        // InvulnerabilityCheck flags DealNoDamage when GetStatValue(player, IsInvulnerable) > 0. We grant it
        // with a +1 stat modifier through the StatsSystem (which responds to our entity id, like heal does).
        // Note: fall damage / scripted kills carry IgnoreImmortalityModes and bypass ALL god mode by design.
        // Apply/remove a status effect on the player (the proven CET approach for godmode/invisibility/etc).
        // ApplyStatusEffect(objID: entEntityID, statusEffectID: TweakDBID, ...rest optional - the VM defaults them).
        // v7: the reapply tick used to re-resolve gi/player/eid/system every 3s (≈5 synthetic engine
        // calls + log lines per tick per active toggle). Cache the resolved context; invalidate on any
        // exception (e.g. stale entity id after a save load) and on 'recap'.
        let statusCtx=null;
        function statusCtxGet(){
            if(statusCtx) return statusCtx;
            const gi=getGI(); if(!gi) return null;
            const p=authPlayer(gi); if(!p) return null;
            const geid=resolveAny(['gameObject','gameEntity'],'GetEntityID'); if(!geid) return null;
            const eid=callFunc(geid.fn, p, geid.retType, []);
            const ses=getSystemFlexible(gi,'gameStatusEffectSystem','GetStatusEffectSystem'); if(!ses) return null;
            const ap=resolveAny(['gameStatusEffectSystem'],'ApplyStatusEffect');
            const rm=resolveAny(['gameStatusEffectSystem'],'RemoveStatusEffect');
            if(!ap||!rm) return null;
            statusCtx={eid:eid, ses:ses, ap:ap, rm:rm};
            return statusCtx;
        }
        function statusApply(on, effectID){
            const c=statusCtxGet(); if(!c) return false;
            const e=on?c.ap:c.rm;
            try{ callFunc(e.fn, c.ses, e.retType, [{raw:c.eid,n:8}, effectID]); return true; }
            catch(ex){ statusCtx=null; dbg('status err: '+ex); return false; }
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
            dbg('  SetLevel '+sigStr(sl.fn));
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
        function addPoints(n, member){
            const devData=getDevData(); if(!devData){ log('points: no PlayerDevelopmentData'); return; }
            const adp=resolveFunc('PlayerDevelopmentData','AddDevelopmentPoints'); if(!adp){ log('AddDevelopmentPoints not found'); return; }
            try{ callFunc(adp.fn, devData, adp.retType, [''+n, member]); log('*** '+member+' points +'+n+' DONE ***'); }
            catch(e){ log('AddDevelopmentPoints err: '+e); } }
        let _expCache={};
        function resolveExport(name){ if(_expCache[name]!==undefined) return _expCache[name]; let r=null;
            try{ if(typeof Module!=='undefined'){
                if(typeof Module.findExportByName==='function'){ const p=Module.findExportByName(null,name); if(p&&!p.isNull()) r=p; }
                if(!r&&typeof Module.getExportByName==='function'){ try{ const p=Module.getExportByName(null,name); if(p&&!p.isNull()) r=p; }catch(e){} }
            }}catch(e){}
            if(!r){ try{ const mods=Process.enumerateModules(); for(const m of mods){ try{ if(typeof m.findExportByName==='function'){ const p=m.findExportByName(name); if(p&&!p.isNull()){ r=p; break; } } }catch(e){} } }catch(e){} }
            if(!r){ try{ const mods=Process.enumerateModules(); for(const m of mods){ const mn=m.name||''; if(mn.indexOf('libobjc')<0&&mn.indexOf('libsystem')<0) continue; let exps=null; try{ exps=(typeof m.enumerateExports==='function')?m.enumerateExports():(typeof Module.enumerateExports==='function'?Module.enumerateExports(mn):null); }catch(e){}
                if(exps){ for(const e of exps){ if(e.name===name){ r=e.address; break; } } } if(r) break; } }catch(e){} }
            _expCache[name]=r; return r; }
        // Translate common CET copy-paste one-liners into our commands (so internet snippets paste directly).
        function cetTranslate(line){ let m;
            // Game.AddToInventory("Items.X" [, qty])   -- by far the most copy-pasted CET call
            m=line.match(/^Game\.AddToInventory\(\s*['"]([A-Za-z0-9_.]+)['"]\s*(?:,\s*([0-9]+))?\s*\)\s*;?\s*$/);
            if(m) return 'give '+m[1]+' '+(m[2]||'1');
            return null; }
        function execute(line){ let raw=line.trim();
            const ct=cetTranslate(raw); if(ct){ log('(cet) '+raw+'  ->  '+ct); raw=ct; }
            const t=raw.split(/\s+/);
            if(t[0]==='tweakload'){ try{ var ex=resolveExport('cybermodman_tweakReload'); if(!ex||ex.isNull()){ log('tweakload: cybermodman_tweakReload export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('tweakload: cybermodman_tweakReload() called - check TweakXL.log'); }catch(e){ log('tweakload err '+e); } return; }   // exempt from in-game guard (drives TweakXL apply)
            if(t[0]==='tweakdumpflat'&&t[1]&&t[2]){ try{ var ex=resolveExport('cybermodman_tweakDumpFlat'); if(!ex||ex.isNull()){ log('tweakdumpflat: export NOT FOUND'); return; } var sr=Memory.allocUtf8String(t[1]); var spp=Memory.allocUtf8String(t[2]); new NativeFunction(ex,'void',['pointer','pointer'])(sr,spp); log('tweakdumpflat: '+t[1]+'.'+t[2]+' -> /tmp/tweakxl_dump.txt'); }catch(e){ log('tweakdumpflat err '+e); } return; }   // dump ONE flat by exact <Record> <prop>
            if(t[0]==='archiveload'){ try{ var ex=resolveExport('cybermodman_archiveReload'); if(!ex||ex.isNull()){ log('archiveload: cybermodman_archiveReload export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveload: cybermodman_archiveReload() called - check ArchiveXL.log'); }catch(e){ log('archiveload err '+e); } return; }   // drives ArchiveXL extension bring-up
            if(t[0]==='archiveprobe'){ try{ var ex=resolveExport('cybermodman_archiveProbeLoadTexts'); if(!ex||ex.isNull()){ log('archiveprobe: cybermodman_archiveProbeLoadTexts export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveprobe: cybermodman_archiveProbeLoadTexts() called - check ArchiveXL.log'); }catch(e){ log('archiveprobe err '+e); } return; }   // wall-B probe: drive LoadTexts directly
            if(t[0]==='archiveinject'){ try{ var ex=resolveExport('cybermodman_archiveInjectName'); if(!ex||ex.isNull()){ log('archiveinject: cybermodman_archiveInjectName export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveinject: cybermodman_archiveInjectName() called - check ArchiveXL.log'); }catch(e){ log('archiveinject err '+e); } return; }   // wall-B exp: overwrite live onscreens text
            if(t[0]==='archivehookname'){ try{ var ex=resolveExport('cybermodman_archiveHookName'); if(!ex||ex.isNull()){ log('archivehookname: cybermodman_archiveHookName export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archivehookname: cybermodman_archiveHookName() called - check ArchiveXL.log'); }catch(e){ log('archivehookname err '+e); } return; }   // wall-B exp: hook item display-name resolver
            if(t[0]==='archivename'){ try{ if(nameHookInstalled){ log('archivename: already installed'); return; } var naddr=base.add(0x378a4b8); var ncalls=0; Interceptor.attach(naddr,{ onEnter:function(a){ this.sret=this.context.x8; }, onLeave:function(r){ try{ var b=this.sret; if(!b||b.isNull()) return; var len=b.add(0x14).readU32(); var heap=(len&0x40000000)!==0; var alen=len&0x3FFFFFFF; var tp=heap?b.readPointer():b; var txt=''; try{ txt=tp.readUtf8String(alen); }catch(e){} if(ncalls<25){ ncalls++; log('namehook #'+ncalls+' x8='+b+' len='+alen+' heap='+heap+' text="'+txt+'"'); } if(txt && txt.indexOf('exington')>=0){ var s='CyberModMan!'; b.writeUtf8String(s); b.add(0x14).writeU32(s.length); b.add(0x18).writePointer(ptr(0)); log('namehook OVERWROTE "'+txt+'" -> '+s); } }catch(e){ log('namehook onLeave err '+e); } } }); nameHookInstalled=true; log('archivename: Frida interceptor attached at '+naddr+' (open inventory, hover a Lexington)'); }catch(e){ log('archivename err '+e); } return; }   // wall-B: DIRECT Frida interceptor on item name resolver (RED4ext plugin hooks dont fire)
            if(t[0]==='debug'){ DBG=(t[1]!=='off'); log('debug logging '+(DBG?'ON':'OFF')); return; }
            if(!player){ log('NOT IN GAME yet: '+line); return; }
            if(t[0]==='give'&&t[1]){ doGive(t[1], Math.max(1,parseInt(t[2]||'1')||1)); return; }
            if(t[0]==='money'&&t[1]){ doGive('Items.money', Math.max(1,parseInt(t[1])||1), true); return; }   // currency: always one bulk add
            if(t[0]==='perks'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Primary'); return; }
            if(t[0]==='attrs'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Attribute'); return; }
            if(t[0]==='relic'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Espionage'); return; }
            if(t[0]==='godmode'){ doGodmode(t[1]!=='off'); return; }
            if(t[0]==='invis'||t[0]==='invisible'){ doInvisible(t[1]!=='off'); return; }
            if(t[0]==='infammo'||t[0]==='ammo'){ doInfammo(t[1]!=='off'); return; }
            if(t[0]==='time'&&t[1]){ doTime(Math.max(0,Math.min(23,parseInt(t[1])||0)), Math.max(0,Math.min(59,parseInt(t[2]||'0')||0))); return; }
            if(t[0]==='slowmo'){ if(t[1]==='off') doSlowmo(false); else doSlowmo(true, parseFloat(t[1])||0.3); return; }
            if(t[0]==='nopolice'||t[0]==='police'){ doNoPolice(t[1]!=='off'); return; }
            if((t[0]==='removeitem'||t[0]==='remove')&&t[1]){ doRemove(t[1], Math.max(1,parseInt(t[2]||'1')||1)); return; }
            if(t[0]==='heal'){ doHeal(); return; }
            if((t[0]==='setfact'||t[0]==='addfact')&&t[1]){ doSetFact(t[1], parseInt(t[2]||'1')||1); return; }
            if(t[0]==='summon'||t[0]==='car'){ doSummon(); return; }
            if(t[0]==='level'&&t[1]){ doLevel(Math.max(1,parseInt(t[1])||1)); return; }
            if((t[0]==='streetcred'||t[0]==='sc')&&t[1]){ doStreetCred(Math.max(1,Math.min(50,parseInt(t[1])||1))); return; }
            if(t[0]==='teleport'||t[0]==='tp'){ doTeleport(t); return; }
            if(t[0]==='mapscan'){ mapscan(); return; }
            if(t[0]==='recap'){ statusCtx=null; devOwner=null; seenVt.clear(); seenClsP.clear(); armCapture(); log('recap: capture hooks re-armed (auto-detach once essentials re-captured)'); return; }
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
        setInterval(function(){ try{
            const c=readFile(CMD); const s=(c||'').trim();
            if(!s){ lastCmd=''; }                         // file empty -> re-arm so an identical next command fires again
            else if(s!==lastCmd){ lastCmd=s; const cmd=s.replace(/^\d+\t/,''); pendingQ.push(cmd); clearFile(CMD); log('queued: '+cmd); armDrain(); }
            if(drainL && !pendingQ.length && !busy){ const l=drainL; drainL=null; l.detach(); }   // command done -> trampoline off
            capCheck();                                    // essentials captured -> capture hooks off
        }catch(e){} }, 120);
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
                Interceptor.attach(base.add(0x34fb8), { onLeave:function(){ try{ clearFile(CMD); }catch(e){} _x2(0); } });
                log('shutdown-exit hook installed (Main+0x34fb8 GOG)'); }
            else log('shutdown-exit: _exit unresolved'); }catch(e){ log('shutdown-exit err: '+e); }
        log('==== CHEATS BUILD v7-lean ready ====');
        // v7: the command trampoline fires on every script call, so it attaches ONLY while a command
        // is pending (armDrain from the poller) and detaches once the queue drains. Steady-state
        // gameplay runs with no hook here.
        let drainL=null;
        function armDrain(){ if(drainL) return; depth=0;
            drainL=Interceptor.attach(execAddr, {
                onEnter: function() { depth++; },
                onLeave: function() {
                    if(depth>0) depth--;
                    if(busy || depth!==0 || !pendingQ.length) return;
                    const cmd=pendingQ.shift(); busy=true;
                    try{ execute(cmd); }catch(e){ log('exec err '+e+' @@STACK: '+((e&&e.stack)?e.stack.replace(/\n/g,' | '):'none')); }
                    busy=false;
                }
            }); }
        // v7: capture hooks also fire on every VM call; once the essentials are in hand they only
        // burn frame time. capCheck() (poller) detaches them; 'recap' re-arms (e.g. after loading a
        // different save, if commands misbehave).
        let capL=null, capL2=null, _capDone=false, _capBusy=false;
        const H_ESSENTIAL=['gameScriptableSystemsContainer','gameTransactionSystem','cpPlayerSystem','gameStatusEffectSystem'].map(function(n){ return '0x'+u64(fnv(n)).toString(16); });
        function haveInst(h){ const m=clsByHash[h]; if(!m) return false; try{ return !!instReg[m.sub(base).add(FV0).toString(16)]; }catch(e){ return false; } }
        function capCheck(){ if(_capDone || !capL) return;
            if(!player || !fromtd) return;
            for(const h of H_ESSENTIAL){ if(!haveInst(h)) return; }
            _capDone=true;
            try{ capL.detach(); }catch(e){} capL=null;
            try{ if(capL2) capL2.detach(); }catch(e){} capL2=null;
            log('capture complete - capture hooks detached; hot path is now hook-free ("recap" re-arms after a save load if needed)'); }
        function armCapture(){ if(capL||capL2) return; _capDone=false;
        // GOG: capture player/ctx at the executor BODY (0x27b9de8). The real `this` lives at
        // frame+0x40 and this fires on every scripted call (faithful port of the Steam capture,
        // which read ctx as a direct executor arg). args: (fn, frame, result, retType).
        capL=Interceptor.attach(base.add(0x27b9de8), {
            onEnter: function(args) {
                try {
                    if(busy) return;                          // skip our own synthetic Exec calls
                    const fr = args[1];
                    if(!fr || fr.isNull()) return;
                    const ctx = fr.add(0x40).readPointer();
                    if(!ctx || ctx.isNull()) return;
                    const vt = ctx.readPointer();
                    if(!vt || vt.isNull()) return;
                    if(playerVt && vt.equals(playerVt)){ player=ctx; addCand(ctx); return; }
                    const vk = vt.toString();
                    if(seenVt.has(vk)) return;
                    seenVt.add(vk);
                    const fn0 = vt.readPointer();
                    if(!fn0 || fn0.isNull()) return;
                    const meta = new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(ctx);
                    if(!meta || meta.isNull()) return;
                    const fv = meta.sub(base).add(FV0).toString(16);
                    instReg[fv] = ctx;
                    const nm = nameOf(meta);
                    if(nm) clsByHash[nm]=meta;   // build name->class-meta map (replaces broken RTTI GetClass)
                    if(nm===PLAYER){ playerVt=vt; player=ctx; addCand(ctx); log('*** PLAYER captured: ctx='+ctx+' vt='+vt+' ***'); }
                } catch(e) {}
            }
        });
        // Universal-caller (FUN_1027ba1b4, args: fn, ctx, frame, result, retType) hook.
        // Captures fromtd AND class/instance metas from ctx. Unlike the body hook (scripted bodies
        // only), ba1b4 sees NATIVE calls too -> captures native system classes the body hook misses
        // (gameTransactionSystem, *System, GameInstance...), which clsByName/instOf need.
        capL2=Interceptor.attach(base.add(0x27ba1b4), {
            onEnter: function(args) {
                if(busy || _capBusy) return;
                try {
                    const fn = args[0];
                    if(!fromtd && fn && !fn.isNull()){
                        const nmh = '0x'+fn.add(0x08).readU64().toString(16);
                        if(nmh==='0x150155547ef75590'){ const rp=fn.add(0x18).readPointer();
                            fromtd = { fn:fn, ctx:args[1], retType: rp.isNull()?ptr(0):rp.readPointer() };
                            log('*** fromtd (TDBID->ItemID) captured: fn='+fn+' ***'); }
                    }
                    // (A) class + instance from ctx (the `this`)
                    const ctx = args[1];
                    if(ctx && !ctx.isNull() && sane(ctx)){
                        const vt = ctx.readPointer();
                        if(vt && !vt.isNull() && sane(vt)){
                            const vk = vt.toString();
                            if(!seenVt.has(vk)){ seenVt.add(vk);
                                _capBusy=true;
                                try {
                                    const gt = vt.add(8).readPointer();
                                    if(gt && !gt.isNull() && sane(gt)){
                                        const meta = new NativeFunction(gt,'pointer',['pointer'])(ctx);
                                        if(meta && !meta.isNull() && sane(meta)){
                                            const fv = meta.sub(base).add(FV0).toString(16); instReg[fv]=ctx; regCls(meta);
                                        }
                                    }
                                } catch(e) {}
                                _capBusy=false;
                            }
                        }
                    }
                    // (B) parent class from fn: captures classes whose FUNCTIONS are called (incl. native
                    // systems with no scripted instance ctx, e.g. gameTimeSystem). Offset auto-detected.
                    if(fn && !fn.isNull() && sane(fn)){
                        if(_parentOff>=0){
                            try{ const P=fn.add(_parentOff).readPointer();
                                if(P && !P.isNull() && sane(P)){ const pk=P.toString();
                                    if(!seenClsP.has(pk)){ seenClsP.add(pk);
                                        _capBusy=true;
                                        try{ const pvt=P.readPointer(); if(pvt && !pvt.isNull() && sane(pvt)) regCls(P); }catch(e){}
                                        _capBusy=false; } } }catch(e){}
                        } else if(clsVals.size>0){
                            try{ for(let off=0x18; off<=0x70; off+=8){ const P=fn.add(off).readPointer();
                                if(P && !P.isNull() && clsVals.has(P.toString())){
                                    _parentDetect[off]=(_parentDetect[off]||0)+1;
                                    if(_parentDetect[off]>=4){ _parentOff=off; dbg('*** fn->parent offset = 0x'+off.toString(16)+' (fn-based class capture enabled) ***'); break; }
                                } } }catch(e){}
                        }
                    }
                } catch(e) { _capBusy=false; }
            }
        });
        }   // end armCapture()
        armCapture();
    }catch(e){ log('MINI-CET v7 FAILED: '+e); }

})();
