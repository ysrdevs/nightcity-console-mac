# Mod import preview (1.9 development)

Add Mod, drag-and-drop, Import VA and the optional installers now prepare an
import for review before copying anything into the game.

1. Quit the game and select mod ZIPs or extracted folders.
2. Wait while NightCity prepares the files in a temporary folder. Archives use
   the same conversion and compatibility checks as the existing installer.
3. Review detected requirements, issues and the expandable list of files to add.
4. Click Install to apply the reviewed batch, or Cancel to discard it.

Known missing requirements, unsupported executable/CET components, duplicate
core mods, conflicting destinations and existing installation receipts block
installation. Existing files are not overwritten. Follow the mod's removal
instructions before replacing an installed version; this is not an in-place
update feature.

The checker can recognize file-based requirements and selected script imports
and settings annotations. Conditional optional imports are treated separately.
Requirements satisfied by another selected package are shown as being in the
same import. Bundled native frameworks are managed by NightCity and cannot be
replaced by files from a downloaded mod.

Detection is not a complete list of a mod's requirements, and a successful
preview is not gameplay certification. Unknown packages remain untested. Check
the author's requirements and download the correct version. The preview does
not infer minimum versions that the package does not reliably declare, download
dependencies automatically, or make Windows native plugins run on macOS.

Before installation, NightCity checks the prepared report and files again,
rechecks the selected game and dependencies, and refuses changed or conflicting
destinations. Copy failures roll back the new files from that batch. If rollback
cannot finish, the error explicitly requests attention and the preparation is
kept for troubleshooting. Script compilation follows installation; a compiler
error still blocks Play and must be resolved before starting the game.

Virtual Atelier, Equipment-EX and Cyberware-EX retain their existing scoped
compatibility adaptations. Noclip and the native framework binaries are not
changed by this feature. The 2.5 Input Loader and Mod Settings checkpoint remains
a separate restore point.
