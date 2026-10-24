import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../overlay/overlay.mm', import.meta.url), 'utf8');
const helpers = source.slice(source.indexOf('static std::set<long> crUsedLockeys'), source.indexOf('// Generate + deploy.'));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ncc-creator-names-'));
try {
  const code = '#import <Foundation/Foundation.h>\n#include <string>\n#include <set>\n#include <cassert>\n' + helpers + String.raw`
int main(int argc, char** argv) {
  @autoreleasepool {
    std::string file = std::string(argv[1]) + "/names.json";
    NSString* p = [NSString stringWithUTF8String:file.c_str()];
    NSString* original = @"{\"7777798\":\"She said \\\"7777799\\\": is a name\",\"7777799\":\"existing\",\"7777800\":\"🔥\"}";
    assert([original writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    auto used = crUsedLockeys(file);
    assert(used.size() == 3 && used.count(7777798) && used.count(7777799) && used.count(7777800));
    assert(crAppendNames(file, 7777801, "Étoile — 東京", 7777802, "quoted \"flavor\"", 7777803, "🔥 ability"));
    NSData* data = [NSData dataWithContentsOfFile:p];
    NSDictionary* names = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert(names.count == 6);
    assert([names[@"7777799"] isEqualToString:@"existing"]);
    assert([names[@"7777800"] isEqualToString:@"🔥"]);
    assert([names[@"7777801"] isEqualToString:@"Étoile — 東京"]);
    assert([names[@"7777802"] isEqualToString:@"quoted \"flavor\""]);
    NSString* broken = @"{broken user data";
    assert([broken writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!crAppendNames(file, 1, "new", 2, "new", 3, "new"));
    assert([[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] isEqualToString:broken]);
  }
  return 0;
}
`;
  const input = path.join(tmp, 'names.mm'), binary = path.join(tmp, 'names-test');
  fs.writeFileSync(input, code);
  const compile = spawnSync('clang++', ['-std=c++17', '-fobjc-arc', '-framework', 'Foundation', input, '-o', binary], { encoding: 'utf8' });
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [tmp], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  console.log('Creator names preserve existing keys, quoted text, Unicode, and malformed user files.');
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
