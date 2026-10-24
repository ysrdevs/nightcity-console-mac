# NightCity Console 1.6.0 handoff

The requested local release milestone passed on October 24, 2026. The user
confirmed the final test4 gameplay checks after Creator creation, uniqueness,
success acknowledgement and save/relaunch persistence had already passed.

## Deliverables

The accepted files are in `/Users/ysr/2077/releases/1.6.0/`:

- `NightCity-Console-for-Mac.zip` and `NightCity-Console-for-Mac.dmg` — unchanged
  copies of the verified test4 packages.
- `SHA256SUMS` — hashes of both distributable files.
- `RELEASE-NOTES.md` — player-facing text for GitHub and Nexus.
- `RELEASE-RECORD.json` — source revisions, artifact hashes, packaging validation
  and the exact scope of user acceptance.

All 303 files inside each packaged app matched the accepted manifest; both apps
passed strict deep signature verification. The app is Developer ID signed but
not notarized. No source push, public upload or Apple submission was performed.
The user controls publication.

## Source and installed test

The release branch is `release/2.5-public-creator`. All local work is committed as
ysrdevs. The native fixes are also preserved as checked patches in `native25/`,
with pinned source trees and build instructions; pushing this branch preserves
those inputs along with the Console changes.

The accepted test app remains under `releases/1.6.0-test4/`, and its launcher points
to `/Users/ysr/2077/test-game-2.5`. Existing custom weapon YAML files and the
custom-name map were preserved during the final Install. The original project
and private development are separate from this release checkout.

See [release validation](RELEASE-1.6.0-TESTING.md) for evidence and limitations,
[release notes](RELEASE-1.6.0-PUBLIC.md) for the upload text, and
[build instructions](RELEASE-BUILD.md) for assembly/signing. Codeware, Virtual
Atelier, CET-Lua and standalone save-editor work remain outside this release.
