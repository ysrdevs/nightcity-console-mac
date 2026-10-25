import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../overlay/overlay.mm', import.meta.url), 'utf8');
const catalogue = source.slice(source.indexOf('#define CR_SLOT_RANGED'), source.indexOf('struct CrStat'));
const effects = source.slice(source.indexOf('struct CrStat'), source.indexOf('static int   g_crBase'));
const generator = source.slice(source.indexOf('static std::string crRecordStem'), source.indexOf('static void crSetStatus'));
const worker = source.slice(source.indexOf('static void crCreateThread'), source.indexOf('static void drawCreatorTab'));
const request = source.slice(source.indexOf('static bool crRequest('), source.indexOf('static void crCreateThread'));
const ids = [...catalogue.matchAll(/"(Items\.Preset_[^"]+)"/g)].map(match => match[1]);
const itemIDs = new Set(fs.readFileSync(new URL('../runtime/cet_catalog.tsv', import.meta.url), 'utf8')
  .split('\n').map(line => line.split('\t')[0]));
assert.equal(ids.length, 37);
assert.equal(new Set(ids).size, ids.length);
for (const id of ids) assert(itemIDs.has(id), `Unknown preset: ${id}`);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ncc-creator-catalog-'));
const prelude = String.raw`
#import <Foundation/Foundation.h>
#include <string>
#include <set>
#include <vector>
#include <atomic>
#include <thread>
#include <chrono>
#include <cassert>
#include <cstring>
#include <cctype>
#include <unistd.h>
static std::string lower(std::string s) { for (char& c : s) c = (char)tolower((unsigned char)c); return s; }
static std::string gameRoot;
static std::string crGameRoot() { return gameRoot; }
`;
function run(name, code) {
  const input = path.join(tmp, name + '.mm'), binary = path.join(tmp, name);
  fs.writeFileSync(input, code);
  const compile = spawnSync('clang++', ['-std=c++17', '-fobjc-arc', '-framework', 'Foundation', input, '-o', binary], { encoding: 'utf8' });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [tmp], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
}

try {
  run('catalogue', prelude + catalogue + effects + generator + String.raw`
int main(int argc, char** argv) {
    @autoreleasepool {
        gameRoot = argv[1];
        const char* legacy[] = { "Lexington", "Saratoga", "Carnage", "Nekomata", "Katana", "Knife", "Baseball_Bat" };
        const char* blueprints[] = { CR_BP_R, CR_BP_R, CR_BP_RA, CR_BP_RN, CR_BP_M, CR_BP_M, CR_BP_M };
        for (int i = 0; i < 7; ++i) {
            assert(std::string(kCrBases[i].preset) == std::string("Items.Preset_") + legacy[i] + "_Default");
            assert(!strcmp(kCrBases[i].bp, blueprints[i]));
            assert(!strcmp(kCrBases[i].slot, i < 4 ? CR_SLOT_RANGED : CR_SLOT_MELEE));
            assert(kCrBases[i].melee == (i >= 4));
        }
        assert(kCrNumCategories == 10);
        assert(crBaseMatches(0, 1, "  pOwEr  LEX "));
        assert(!crBaseMatches(0, 2, "lex"));
        assert(!crBaseMatches(-1, 0, ""));
        assert(!crBaseMatches(kCrNumBases, 0, ""));
        assert(crVisibleSelection(3, 0, "TECH SNIPER") == 3);
        assert(crVisibleSelection(0, 0, "Tech Sniper") == 3);
        assert(crVisibleSelection(0, 0, "does not exist") == -1);
        assert(crVisibleSelection(-1, 0, "") == 0);
        assert(crVisibleSelection(7, 0, "") == 7); // Clearing search preserves a matching selection.
        for (int category = 1; category < kCrNumCategories; ++category)
            assert(crVisibleSelection(-1, category, "") >= 0);
        int smart = 0, throwable = 0;
        for (int i = 0; i < kCrNumBases; ++i) {
            smart += crBaseMatches(i, 0, "smart");
            throwable += crBaseMatches(i, 0, "throwable");
        }
        assert(smart == 3 && throwable == 3);

        NSFileManager* fm = [NSFileManager defaultManager];
        NSString* root = [NSString stringWithUTF8String:gameRoot.c_str()];
        NSString* red4ext = [root stringByAppendingPathComponent:@"red4ext"];
        NSString* tweaks = [root stringByAppendingPathComponent:@"r6/tweaks"];
        assert([fm createDirectoryAtPath:red4ext withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([fm createDirectoryAtPath:tweaks withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString* namesPath = [red4ext stringByAppendingPathComponent:@"cybermodman_names.json"];
        NSString* oldNames = @"{\"7777798\":\"My old iconic\",\"7777799\":\"Existing flavor\",\"7777800\":\"Existing ability\"}";
        assert([oldNames writeToFile:namesPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        NSString* oldWeapon = [tweaks stringByAppendingPathComponent:@"cybermodman_CyberModManOldWeapon.yaml"];
        NSString* oldYAML = @"Items.CyberModManOldWeapon:\n  $base: Items.Preset_Lexington_Default\n  displayName: LocKey#7777798\n";
        assert([oldYAML writeToFile:oldWeapon atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        bool selected[64] = {};
        for (int i = 0; i < kCrNumBases; ++i) {
            std::string error;
            long keys[3] = {};
            std::string name = "Catalog Test " + std::to_string(i);
            std::string id = crGenWeapon(i, name, "Flavor", "Ability", selected, keys, error);
            assert(!id.empty() && error.empty());
            assert(keys[0] == 7777801 + 3 * i && keys[2] == keys[0] + 2);
            NSString* file = [tweaks stringByAppendingPathComponent:
                [NSString stringWithFormat:@"cybermodman_%s.yaml", id.substr(6).c_str()]];
            NSData* before = [NSData dataWithContentsOfFile:file];
            NSString* yaml = [[NSString alloc] initWithData:before encoding:NSUTF8StringEncoding];
            assert(([yaml containsString:[NSString stringWithFormat:@"$base: %s\n", kCrBases[i].preset]]));
            assert(([yaml containsString:[NSString stringWithFormat:@"blueprint: %s\n", kCrBases[i].bp]]));
            assert(([yaml containsString:[NSString stringWithFormat:@"slot: %s\n", kCrBases[i].slot]]));
            assert([yaml containsString:@"!append IconicWeapon"]);
            assert(crGenWeapon(i, name, "Different", "Different", selected, keys, error).empty());
            assert([before isEqualToData:[NSData dataWithContentsOfFile:file]]);
        }
        assert([[NSString stringWithContentsOfFile:oldWeapon encoding:NSUTF8StringEncoding error:nil] isEqualToString:oldYAML]);
        NSDictionary* names = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:namesPath] options:0 error:nil];
        assert(names.count == 3 + 37 * 3);
        assert([names[@"7777798"] isEqualToString:@"My old iconic"]);
        assert([names[@"7777799"] isEqualToString:@"Existing flavor"]);
        assert([names[@"7777800"] isEqualToString:@"Existing ability"]);
        NSData* preservedNames = [NSData dataWithContentsOfFile:namesPath];
        std::string error; long keys[3] = {};
        assert(crGenWeapon(-1, "Invalid", "", "", selected, keys, error).empty());
        assert(crGenWeapon(kCrNumBases, "Invalid", "", "", selected, keys, error).empty());
        assert([preservedNames isEqualToData:[NSData dataWithContentsOfFile:namesPath]]);
    }
}
`);
  // Run the actual worker with boundary doubles: a failed preflight must never reach
  // file generation or apply; a success must carry the captured selection through once.
  run('preflight-order', prelude + catalogue + String.raw`
static std::atomic<bool> g_crBusy{true};
static std::vector<std::string> calls;
static bool ready = false;
static int chosen = 29;
static void crSetStatus(const std::string&) {}
static bool crRequest(const char* op, const std::string&, const long*, std::string& message, const CrBase* base = nullptr) {
    calls.push_back(op);
    if (std::string(op) == "check") {
        assert(base == &kCrBases[chosen]);
        assert(std::string(base->preset) == "Items.Preset_Ashura_Default");
        message = "Missing base weapon; no files were written.";
        return ready;
    }
    assert(base == nullptr);
    return true;
}
static std::string crGenWeapon(int base, const std::string&, const std::string&, const std::string&, const bool*, long*, std::string&) {
    assert(base == chosen); calls.push_back("generate"); return "Items.CyberModManTest";
}
` + worker + String.raw`
int main() {
    crCreateThread(chosen, "Test", "", "", {});
    assert((calls == std::vector<std::string>{"check"}) && !g_crBusy);
    calls.clear(); ready = true; g_crBusy = true;
    crCreateThread(chosen, "Test", "", "", {});
    assert((calls == std::vector<std::string>{"check", "generate", "apply"}) && !g_crBusy);
    calls.clear(); g_crBusy = true;
    crCreateThread(-1, "Test", "", "", {});
    assert(calls.empty() && !g_crBusy);
}
`);
  run('preflight-wire', prelude + catalogue + String.raw`
static const char* CREATOR_REQ_PATH;
static const char* CREATOR_RES_PATH;
` + request + String.raw`
int main(int argc, char** argv) {
    std::string requestPath = std::string(argv[1]) + "/request.json";
    std::string responsePath = std::string(argv[1]) + "/response.json";
    CREATOR_REQ_PATH = requestPath.c_str(); CREATOR_RES_PATH = responsePath.c_str();
    for (int mode = 0; mode < 4; ++mode) {
        unlink(CREATOR_REQ_PATH); unlink(CREATOR_RES_PATH);
        std::thread server([mode] {
            @autoreleasepool {
                NSDictionary* request = nil;
                for (int attempt = 0; attempt < 100 && !request; ++attempt) {
                    NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:CREATOR_REQ_PATH]];
                    if (data) request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!request) std::this_thread::sleep_for(std::chrono::milliseconds(10));
                }
                assert(request);
                assert([request[@"baseRecord"] isEqual:@"Items.Preset_Lexington_Default"]);
                assert([request[@"blueprint"] isEqual:@"Items.Iconic_Ranged_Weapon_Blueprint"]);
                NSMutableDictionary* response = [@{@"id":request[@"id"], @"ok":@(mode != 3), @"message":@"Checked"} mutableCopy];
                if (mode != 1) {
                    response[@"baseRecord"] = mode == 2 ? @"Items.Preset_Katana_Default" : request[@"baseRecord"];
                    response[@"blueprint"] = request[@"blueprint"];
                }
                NSData* data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                assert([data writeToFile:[NSString stringWithUTF8String:CREATOR_RES_PATH] options:NSDataWritingAtomic error:nil]);
            }
        });
        std::string message;
        const bool okay = crRequest("check", "", nullptr, message, &kCrBases[0]);
        server.join();
        assert(okay == (mode == 0)); // No success from an old runtime, a mismatched selection or a failure.
    }
}
`);
  console.log('37 catalogue presets, category/search selection, legacy profiles/files/names, duplicate protection, preflight ordering and wire handshake passed.');
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
