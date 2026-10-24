# NightCity Console 1.6.0 handoff

The requested local release milestone passed on October 24, 2026. The user
confirmed the final test4 gameplay checks after Creator creation, uniqueness,
success acknowledgement and save/relaunch persistence had already passed.

## Deliverables

The accepted files are in `/Users/ysr/2077/releases/1.6.0/`:

- `NightCity-Console-for-Mac.zip` and `NightCity-Console-for-Mac.dmg` — notarized
  release packages. The ZIP includes the stapled app; the DMG is also stapled.
- `SHA256SUMS` — hashes of both distributable files.
- `RELEASE-NOTES.md` — player-facing text for GitHub and Nexus.
- `RELEASE-RECORD.json` — source revisions, artifact hashes, packaging validation
  and the exact scope of user acceptance.

Apple accepted both the app and DMG submissions with no reported issues. All 303
original signed app files remained unchanged from the accepted test4 build;
stapling added the app's ticket at `Contents/CodeResources`. The app passed strict
deep signature verification, stapler validation and Gatekeeper's
`Notarized Developer ID` assessment. No rebuilding or re-signing was performed.
Independent ZIP extraction and read-only DMG mounting matched all 304 final app
hashes and permissions. Both packaged apps and the DMG passed signature, ticket
and Gatekeeper checks; DMG integrity and its Applications shortcut also passed.
The user controls source pushes and GitHub/Nexus publication; neither was performed.

Apple submission IDs and logs are recorded in
[release validation](RELEASE-1.6.0-TESTING.md). These completed Apple submissions
were explicitly requested by the user.

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
