// No game is launched or modified. Exercise the real shell preflight and reset helper with fixtures.
// Optional argument: the official v1.5.0-beta.2 ZIP, to test dependency import from an empty checkout.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'nightcity-gog-test-'));
let passed = 0;
function test(name, fn) { fn(); passed++; console.log(`PASS ${name}`); }
function write(relative, content) {
    const target = path.join(temp, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
    return target;
}
function bash(script, args = [], env = {}) {
    return spawnSync('/bin/bash', [script, ...args], {
        encoding: 'utf8', env: { ...process.env, ...env }, timeout: 30000,
    });
}
function sha(file) { return createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }

try {
    const launchSource = fs.readFileSync(path.join(root, 'dev/launch.sh'), 'utf8');
    const marker = 'echo "==> building overlay"';
    assert(launchSource.includes(marker));
    // Stop before any build, installation, signing, or launch. Append only an observation of store choice.
    const preflight = write('preflight.sh', launchSource.split(marker)[0] +
        '\nprintf "RESULT:%s|%s|%s\\n" "$HOOK" "${SteamAppId-unset}" "${RED4EXT_GUM_HOOKS-unset}"\n');
    for (const [kind, relative, bundleID, framework] of [
        ['GOG ID', 'gog', 'com.cdprojektred.cyberpunk.gog', false],
        ['GOG framework', 'gog-fallback', 'other', true],
        ['GOG takes priority', 'gog/steamapps/common/Game', 'com.cdprojektred.cyberpunk.gog', false],
        ['Steam', 'steamapps/common/Game', 'other', false],
        ['Unknown', 'unknown', 'other', false],
    ]) {
        const game = path.join(temp, relative);
        write(`${relative}/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077`, 'fixture only');
        write(`${relative}/Cyberpunk2077.app/Contents/Info.plist`,
            `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleID}</string></dict></plist>`);
        if (framework) write(`${relative}/Cyberpunk2077.app/Contents/Frameworks/libGameServicesGOG.dylib`, 'fixture only');
        test(`developer preflight: ${kind}`, () => {
            const result = bash(preflight, [], { CP2077_DIR: game, SteamAppId: 'inherited', RED4EXT_GUM_HOOKS: 'scoped' });
            if (kind === 'Unknown') {
                assert.equal(result.status, 1);
                assert.match(result.stdout, /Unsupported game build/);
            } else {
                assert.equal(result.status, 0, result.stderr);
                assert.match(result.stdout, kind === 'Steam'
                    ? /RESULT:red4ext_hooks\.js\|1091500\|scoped/
                    : /RESULT:red4ext_hooks_gog\.js\|unset\|unset/);
            }
            assert(!fs.existsSync(path.join(game, 'red4ext')));
        });
    }

    for (const script of ['red4ext_hooks.js', 'red4ext_hooks_gog.js']) {
        const source = fs.readFileSync(path.join(root, 'runtime', script), 'utf8');
        const helper = source.match(/function resetDevelopment\(method, label\)\{[\s\S]*?\n        \}/)?.[0];
        assert(helper, `${script}: reset helper missing`);
        for (const method of ['ResetNewPerks', 'ResetAttributes']) {
            for (const scenario of ['ok', 'no instance', 'no method', 'static', 'params', 'unreadable signature', 'call error']) {
                test(`${script} ${method}: ${scenario}`, () => {
                    const owner = {};
                    const calls = [], logs = [];
                    const descriptor = { isStatic: scenario === 'static', retType: {}, fn: {
                        add(offset) {
                            assert.equal(offset, 0x30);
                            if (scenario === 'unreadable signature') throw new Error('unreadable');
                            return { readU32: () => scenario === 'params' ? 1 : 0 };
                        },
                    } };
                    const reset = vm.runInNewContext(`(${helper})`, {
                        getDevData: () => scenario === 'no instance' ? null : owner,
                        resolveFunc(cls, name) {
                            assert.equal(cls, 'PlayerDevelopmentData'); assert.equal(name, method);
                            return scenario === 'no method' ? null : descriptor;
                        },
                        callFunc(fn, context, ret, args) {
                            calls.push(context); assert.equal(context, owner);
                            assert.equal(fn, descriptor.fn); assert.equal(args.length, 0);
                            if (scenario === 'call error') throw new Error('test failure');
                        },
                        log: s => logs.push(s),
                    });
                    reset(method, 'test');
                    assert.equal(calls.length, ['ok', 'call error'].includes(scenario) ? 1 : 0);
                    assert.equal(logs.some(s => s.includes('DONE')), scenario === 'ok');
                    assert(logs.length > 0);
                });
            }
        }
    }

    const fetcher = write('repo/tools/fetch-deps.sh', fs.readFileSync(path.join(root, 'tools/fetch-deps.sh')));
    const importEnv = { CP2077_DIR: path.join(temp, 'no-game'), SCC_SRC: path.join(temp, 'no-scc') };
    test('missing dependencies report every file instead of exiting at the first copy', () => {
        const result = bash(fetcher, [], importEnv);
        assert.equal(result.status, 1, result.stderr);
        for (const file of ['RED4ext.dylib', 'FridaGadget.dylib', 'TweakXL.dylib', 'ArchiveXL.dylib', 'config.ini', 'cyberpunk2077_addresses.json']) {
            assert(result.stdout.includes(`MISSING or empty: deps/${file}`));
        }
    });
    test('ZIP checksum mismatch is rejected before importing any dependency', () => {
        const result = bash(fetcher, ['--from-zip', path.join(root, 'README.md')], importEnv);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /checksum mismatch/);
        assert.equal(fs.readdirSync(path.join(temp, 'repo/deps')).length, 0);
    });
    if (process.argv[2]) {
        const zip = path.resolve(process.argv[2]);
        test('clean ZIP import includes exact core binaries and both plugins with siblings', () => {
            const result = bash(fetcher, ['--from-zip', zip], importEnv);
            assert.equal(result.status, 0, result.stdout + result.stderr);
            assert.equal(sha(path.join(temp, 'repo/deps/FridaGadget.dylib')), 'b179993600ef63a41c483ca4067567b40da7785480c55ae66eac095dcdcedf8f');
            assert.equal(sha(path.join(temp, 'repo/deps/RED4ext.dylib')), 'ae94730a81d7b9ece32579dec5922198f6b0b9064396b6aaf52037d2753f09da');
            assert.equal(sha(path.join(temp, 'repo/deps/TweakXL.dylib')), '8599e7de0cea311ac697e3b866044f10ca411f590b6fa6052a80393f9e41b9ee');
            for (const plugin of ['TweakXL', 'ArchiveXL']) {
                for (const lib of ['libspdlog.1.17.dylib', 'libfmt.12.dylib', 'libyaml-cpp.0.9.dylib']) {
                    assert(fs.statSync(path.join(temp, `repo/deps/plugins/${plugin}/${lib}`)).size > 0);
                }
            }
        });
        test('repeated import preserves existing pinned binaries', () => {
            write('repo/deps/TweakXL.dylib', 'deliberate pinned fixture');
            const result = bash(fetcher, ['--from-zip', zip], importEnv);
            assert.equal(result.status, 0, result.stdout + result.stderr);
            assert.equal(fs.readFileSync(path.join(temp, 'repo/deps/TweakXL.dylib'), 'utf8'), 'deliberate pinned fixture');
            assert(!fs.readdirSync(path.join(temp, 'repo/deps')).some(f => f.startsWith('.import.')));
        });
    }
    console.log(`${passed} checks passed. No game was launched or modified.`);
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
