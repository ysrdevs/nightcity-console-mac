#!/usr/bin/env python3
"""Offline import contract tests. Creates disposable games; never launches one."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, stat, subprocess, tempfile, time, unicodedata, zipfile
p=argparse.ArgumentParser();p.add_argument('--dotnet',required=True);p.add_argument('--nctool',required=True);p.add_argument('--keep',action='store_true');p.add_argument('--va-zip');p.add_argument('--equipment-zip');p.add_argument('--rippers-folder');a=p.parse_args()
root=pathlib.Path(tempfile.mkdtemp(prefix='nightcity-import-tests-'));tool=[a.dotnet,a.nctool];checks=0

def run(*args,ok=None):
    r=subprocess.run(tool+list(map(str,args)),capture_output=True,text=True,timeout=45)
    if ok is not None: assert (r.returncode==0)==ok,(args,r.returncode,r.stdout,r.stderr)
    return r

def write(path,data='test'):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data if isinstance(data,bytes) else data.encode());return path

def game(name):
    g=root/name;write(g/'Cyberpunk2077.app/Contents/Info.plist',plistlib.dumps({'CFBundleShortVersionString':'2.5.0'}));return g

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inventory(g):return {str(p.relative_to(g)):sha(p) for p in g.rglob('*') if p.is_file()}
def prepare(name,files,g=None):
    g=g or game(name+'-game');s=root/(name+'-source');s.mkdir()
    for rel,data in files.items():write(s/rel,data)
    w=root/(name+'-work');r=run('prepare-import',s,g,w);return g,s,w,r

def report(w):return json.loads((w/'report.json').read_text())
def request(g,workspaces,name='request'):
    q=root/(name+'.json');q.write_text(json.dumps({'gameRoot':str(g),'packages':[{'workspace':str(w),'reportSHA256':sha(w/'report.json'),'receiptName':f'import-{i}.json'} for i,w in enumerate(workspaces)]}));return q

def passed(name):
    global checks;checks+=1;print('PASS',name)
try:
    g,s,w,r=prepare('simple',{'wrapper/r6/scripts/Foo/Foo.reds':'module Foo\n','wrapper/r6/input/Foo.xml':'<root/>','wrapper/r6/tweaks/foo.yaml':'foo: 1','README.md':'hi'})
    assert r.returncode==0,(r.stdout,r.stderr)
    assert len(inventory(g))==1 and inventory(s)==inventory(w/'source')
    rep=report(w);assert len(rep['files'])==3 and rep['gameVersion']=='2.5.0' and rep['gameInfoSHA256']==sha(g/'Cyberpunk2077.app/Contents/Info.plist')
    passed('preparation read-only, source unchanged, input mappings included')
    run('commit-import',request(g,[w]),ok=True)
    assert (g/'r6/input/Foo.xml').read_text()=='<root/>'
    receipt=json.loads((g/'red4ext/nightcity/mods/import-0.json').read_text());assert len(receipt['files'])==3 and receipt['name']=='simple-source'
    before=inventory(g);run('commit-import',request(g,[w],'repeat'),ok=False);assert inventory(g)==before
    passed('commit receipt and repeat refusal')

    for label,change in [('source',lambda w:write(w/'source/r6/scripts/Foo.reds','changed')),('payload',lambda w:write(w/'game/r6/scripts/Foo.reds','changed')),('extra-source',lambda w:write(w/'source/extra.txt','extra')),('extra-payload',lambda w:write(w/'game/r6/scripts/extra.reds','extra'))]:
        g,s,w,r=prepare(label,{'r6/scripts/Foo.reds':'//original'});assert r.returncode==0
        q=request(g,[w],label);before=inventory(g);change(w);run('commit-import',q,ok=False);assert inventory(g)==before;passed(label+' tamper refusal')
    g,s,w,r=prepare('report',{'r6/scripts/Foo.reds':'//x'});q=request(g,[w],'report');write(w/'report.json',(w/'report.json').read_text()+' ');run('commit-import',q,ok=False);assert len(inventory(g))==1;passed('reviewed report hash refusal')
    g,s,w,r=prepare('game-change',{'r6/scripts/Foo.reds':'//x'});q=request(g,[w],'game-change');write(g/'Cyberpunk2077.app/Contents/Info.plist',plistlib.dumps({'CFBundleShortVersionString':'2.6.0'}));run('commit-import',q,ok=False);assert len(inventory(g))==1;passed('changed game refusal')
    g=game('preexisting-game');write(g/'r6/scripts/Foo.reds','keep');before=inventory(g);g,s,w,r=prepare('preexisting',{'r6/scripts/Foo.reds':'replace'},g);assert r.returncode!=0 and any(x['code']=='existingDestination' for x in report(w)['issues']);run('commit-import',request(g,[w],'existing'),ok=False);assert inventory(g)==before;passed('preexisting content preserved')
    g,s,w,r=prepare('late-existing',{'r6/scripts/Foo.reds':'replace'});write(g/'r6/scripts/Foo.reds','keep');before=inventory(g);run('commit-import',request(g,[w],'late'),ok=False);assert inventory(g)==before;passed('destination created after preview preserved')
    g,s,w,r=prepare('native',{'r6/scripts/Foo.reds':'//x','red4ext/plugins/NewNative/a.dll':'MZ','bin/x64/plugins/cyber_engine_tweaks/mods/a/init.lua':'x'});assert r.returncode!=0 and len([x for x in report(w)['skipped'] if x['blocking']])==2;run('commit-import',request(g,[w],'native'),ok=False);assert len(inventory(g))==1;passed('native and CET partial packages block')
    g,s,w,r=prepare('foundation',{'r6/scripts/Foo.reds':'//x','red4ext/plugins/Codeware/Codeware.dll':'MZ','r6/scripts/Codeware/Codeware.reds':'bad','red4ext/plugins/ModSettings/ModSettings.dll':'MZ','red4ext/plugins/input_loader/a.ini':'bad'});assert r.returncode==0 and len(report(w)['files'])==1 and len(report(w)['skipped'])==4;passed('bundled foundations preserved and explained')
    g,s,w,r=prepare('foundation-archives',{'r6/scripts/Foo.reds':'//x','archive/pc/mod/ModSettings.archive':'native UI','archive/pc/mod/ModSettings.archive.xl':'resources','archive/pc/mod/Codeware.archive':'native UI','archive/pc/mod/ArchiveXL.archive.xl':'resources','archive/pc/mod/thirdparty.archive.xl':'thirdparty'})
    assert r.returncode==0 and len(report(w)['files'])==2 and len(report(w)['skipped'])==4
    assert any(f['destination']=='red4ext/plugins/ArchiveXL/Bundle/thirdparty.archive.xl' for f in report(w)['files']);passed('foundation companion archives preserved; thirdparty XL allowed')
    g,s,w,r=prepare('duplicate',{'a/r6/scripts/Foo.reds':'a','b/r6/scripts/Foo.reds':'b'});assert r.returncode!=0 and any(x['code']=='duplicateDestination' for x in report(w)['issues']);passed('within-package destination collision')
    g=game('batch-game');_,_,wa,r=prepare('batch-a',{'r6/scripts/Foo.reds':'a'},g);_,_,wb,r=prepare('batch-b',{'r6/scripts/Foo.reds':'b'},g);run('commit-import',request(g,[wa,wb],'batch'),ok=False);assert len(inventory(g))==1;passed('batch collision before writes')
    g=game('batch-ok-game');_,_,wa,r=prepare('batch-ok-a',{'r6/scripts/A.reds':'a'},g);_,_,wb,r=prepare('batch-ok-b',{'r6/input/B.xml':'<root/>'},g);run('commit-import',request(g,[wa,wb],'batch-ok'),ok=True);assert len(list((g/'red4ext/nightcity/mods').glob('*.json')))==2;passed('two-package transaction')

    # Receipt parent is deliberately a file: failure occurs after payload copies,
    # exercising rollback without injecting behavior into the production helper.
    g,s,w,r=prepare('rollback',{'r6/scripts/A.reds':'a','r6/input/B.xml':'b'});write(g/'red4ext/nightcity/mods','existing-data');before=inventory(g);r=run('commit-import',request(g,[w],'rollback'),ok=False);assert 'rolled back' in r.stderr and inventory(g)==before,(r.stdout,r.stderr,inventory(g));passed('mid-transaction failure rolls back entire batch')

    for name,entries in [('traversal',[('../escape','x')]),('absolute',[('/escape','x')]),('backslash',[('r6\\scripts\\x.reds','x')]),('duplicate-zip',[('r6/scripts/Foo.reds','a'),('r6/scripts/Foo.reds','b')]),('case-zip',[('r6/scripts/Foo/a.reds','a'),('r6/scripts/foo/b.reds','b')])]:
        z=root/(name+'.zip');g=game(name+'-game');w=root/(name+'-work')
        with zipfile.ZipFile(z,'w') as f:
            for path,data in entries:f.writestr(path,data)
        run('prepare-import',z,g,w,ok=False);assert len(inventory(g))==1;passed(name+' refused')
    z=root/'link.zip';g=game('linkzip-game');w=root/'linkzip-work'
    with zipfile.ZipFile(z,'w') as f:
        i=zipfile.ZipInfo('r6/scripts/link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;f.writestr(i,'/tmp')
    run('prepare-import',z,g,w,ok=False);passed('ZIP symlink refused')
    g=game('symlink-game');s=root/'symlink-source';s.mkdir();(s/'link').symlink_to(root/'simple-source',target_is_directory=True);run('prepare-import',s,g,root/'symlink-work',ok=False);passed('source symlink refused')
    g=game('fifo-game');s=root/'fifo-source';s.mkdir();os.mkfifo(s/'fifo');run('prepare-import',s,g,root/'fifo-work',ok=False);passed('source FIFO refused without blocking')
    g,s,w,r=prepare('dest-link',{'r6/scripts/Foo.reds':'x'});outside=root/'outside';outside.mkdir();(g/'r6').symlink_to(outside,target_is_directory=True);run('commit-import',request(g,[w],'dest-link'),ok=False);assert not list(outside.iterdir());passed('destination symlink refused')
    g=game('compat-game');s=root/'compat-source';write(s/'r6/scripts/CyberwareEx.reds','public abstract class CyberwareEx { public static func Version() -> String = "999"; }');w=root/'compat-work';run('prepare-import',s,g,w,ok=False);assert any(x['blocking'] for x in report(w)['issues']);passed('compatibility failure has blocking report')
    g=game('zip-ok-game');z=root/'zip-ok.zip';w=root/'zip-ok-work'
    with zipfile.ZipFile(z,'w') as f:f.writestr('Named/r6/input/Foo.xml','<root/>')
    before=sha(z);run('prepare-import',z,g,w,ok=True);assert sha(z)==before;run('commit-import',request(g,[w],'zip-ok'),ok=True);passed('valid ZIP import preserves original ZIP')
    g,s,w,r=prepare('external-change',{'r6/scripts/Original.reds':'reviewed'});assert r.returncode==0;write(s/'r6/scripts/Original.reds','external-edit');run('commit-import',request(g,[w],'external-change'),ok=True);assert (g/'r6/scripts/Original.reds').read_text()=='reviewed';passed('external source edits do not replace reviewed snapshot')
    g,s,w,r=prepare('same-workspace',{'r6/scripts/Foo.reds':'x'});run('commit-import',request(g,[w,w],'same-workspace'),ok=False);assert len(inventory(g))==1;passed('same workspace repeated in batch refused')
    g,s,w,r=prepare('no-r6',{'tweaks/Mod/a.yaml':'a: 1','scripts/Foo/Foo.reds':'module Foo\n','scripts/Codeware/x.reds':'x','input/Foo.xml':'<root/>'});assert r.returncode==0,(r.stdout,r.stderr)
    assert sorted(f['destination'] for f in report(w)['files'])==['r6/input/Foo.xml','r6/scripts/Foo/Foo.reds','r6/tweaks/Mod/a.yaml'];run('commit-import',request(g,[w],'no-r6'),ok=True);assert (g/'r6/tweaks/Mod/a.yaml').read_text()=='a: 1' and not (g/'r6/scripts/Codeware').exists();passed('top-level tweaks/scripts/input without r6/ are placed in r6/, foundations still protected')
    g,s,w,r=prepare('mixed-r6',{'tweaks/a.yaml':'a: 1','r6/scripts/Foo.reds':'x'});assert r.returncode==0 and [f['destination'] for f in report(w)['files']]==['r6/scripts/Foo.reds'];passed('packages that already have r6/ are not guessed')
    g,s,w,r=prepare('Folder.v1.2',{'r6/scripts/Foo.reds':'x'});assert report(w)['packageName']=='Folder.v1.2-source';passed('dotted folder display name preserved')
    g=game('containment-game');s=root/'containment-source';write(s/'r6/scripts/Foo.reds','x');before=inventory(g)
    alias=g.with_name(g.name.upper());run('prepare-import',s,g,alias/'preview',ok=False);assert inventory(g)==before and not (g/'preview').exists();passed('case alias workspace cannot enter game')
    g=game('containment-caf\u00e9');alias=g.with_name(unicodedata.normalize('NFD',g.name));before=inventory(g);run('prepare-import',s,g,alias/'preview',ok=False);assert inventory(g)==before and not (g/'preview').exists();passed('Unicode alias workspace cannot enter game')
    g=game('containment-source-game');write(g/'downloads/r6/scripts/Foo.reds','x');before=inventory(g);run('prepare-import',g.with_name(g.name.upper())/'downloads',g,root/'forbidden-source-work',ok=False);assert inventory(g)==before;passed('case alias source inside game refused')
    g,s,w,r=prepare('running',{'r6/scripts/Foo.reds':'x'});stub=root/'Cyberpunk2077';subprocess.run(['/usr/bin/clang','-x','c','-o',str(stub),'-'],input='#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n',text=True,check=True);process=subprocess.Popen([str(stub)])
    try:
        time.sleep(.15);assert process.poll() is None,'test process exited early';r=run('commit-import',request(g,[w],'running'),ok=False);assert 'Quit Cyberpunk' in r.stderr and len(inventory(g))==1;passed('external running game name refuses commit')
    finally:process.terminate();process.wait()
    for label,source in [('VA',a.va_zip),('Equipment',a.equipment_zip),('Rippers',a.rippers_folder)]:
        if not source:continue
        source=pathlib.Path(source);before=inventory(source) if source.is_dir() else sha(source);g=game(label+'-real-game');w=root/(label+'-real-work');run('prepare-import',source,g,w,ok=True);rep=report(w);assert rep['files'] and len(inventory(g))==1
        assert (inventory(source) if source.is_dir() else sha(source))==before
        if label in ('VA','Equipment'):assert any(f['destination'].startswith('archive/Mac/mod/') and f['destination'].endswith('.archive.xl') for f in rep['files'])
        run('commit-import',request(g,[w],label+'-real'),ok=True)
        for f in rep['files']:assert sha(g/f['destination'])==f['sha256']
        passed(label+' real package prepared/committed exact reviewed payload')
    print(f'{checks} checks passed; workspace: {root}')
finally:
    if not a.keep:shutil.rmtree(root)
