#!/usr/bin/env python3
"""Create and verify one release DMG without detaching unrelated images."""
import argparse
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import subprocess
import sys

HDIUTIL = "/usr/bin/hdiutil"
DEVICE = re.compile(r"^/dev/(disk[0-9]+)(?:s[0-9]+)*$")
ROOT_DEVICE = re.compile(r"^/dev/disk[0-9]+$")


@dataclass(frozen=True)
class Attachment:
    image_path: str
    devices: tuple
    mounted: bool


def canonical_image_path(path):
    # hdiutil can also report non-file URLs. They cannot match this local output.
    return str(Path(path).resolve()) if Path(path).is_absolute() else None


def parse_attachments(data):
    record = plistlib.loads(data)
    if not isinstance(record, dict) or not isinstance(record.get("images"), list):
        raise ValueError("hdiutil info did not return an images array")
    images = []
    for entry in record["images"]:
        if not isinstance(entry, dict):
            raise ValueError("Malformed hdiutil image record")
        path, entities = entry.get("image-path"), entry.get("system-entities")
        if not isinstance(path, str) or not path or not isinstance(entities, list):
            raise ValueError("Missing hdiutil image path or system entities")
        devices, mounted = [], False
        for entity in entities:
            if not isinstance(entity, dict):
                raise ValueError("Malformed hdiutil system entity")
            device = entity.get("dev-entry")
            if not isinstance(device, str) or not DEVICE.fullmatch(device):
                raise ValueError("Unexpected hdiutil device entry")
            devices.append(device)
            # Even an empty/unexpected mount-point field is not proof of an
            # unmounted device. Refuse cleanup rather than make that assumption.
            mounted |= "mount-point" in entity
        images.append(Attachment(path, tuple(devices), mounted))
    return tuple(images)


def matching_images(images, output):
    target = canonical_image_path(str(output))
    if target is None:
        raise ValueError("The checked output DMG path must be absolute")
    return [image for image in images if canonical_image_path(image.image_path) == target]


def aliased_images(images, output):
    # Case/Unicode aliases and hard links can have a different realpath spelling
    # but still identify the output. They forbid overwriting, not authorize detach.
    aliases = []
    target = canonical_image_path(str(output))
    for image in images:
        path = canonical_image_path(image.image_path)
        if path is None or path == target:
            continue
        try:
            if Path(path).samefile(output):
                aliases.append(image)
        except FileNotFoundError:
            pass
    return aliases


def require_unattached(images, output):
    if matching_images(images, output) or aliased_images(images, output):
        raise ValueError(f"Output DMG is already attached; refusing to overwrite it: {output}")


def device_family(device):
    return "/dev/" + DEVICE.fullmatch(device).group(1)


def cleanup_device(before, after, output):
    """Return the sole safe new root device, or None; never perform an action."""
    require_unattached(before, output)
    if aliased_images(after, output):
        raise ValueError("Output DMG is attached through an unexpected path alias; no devices were detached")
    matches = matching_images(after, output)
    if not matches:
        return None
    if len(matches) != 1:
        raise ValueError("Ambiguous output DMG attachments; no devices were detached")
    image = matches[0]
    roots = [device for device in image.devices if ROOT_DEVICE.fullmatch(device)]
    if image.mounted:
        raise ValueError("Output DMG has a mount point; no devices were detached")
    if len(roots) != 1 or len(set(image.devices)) != len(image.devices):
        raise ValueError("Output DMG lacks one unambiguous root device; no devices were detached")
    root = roots[0]
    if any(device_family(device) != root for device in image.devices):
        raise ValueError("Output DMG spans multiple device families; no devices were detached")
    if any(device_family(device) == root for old in before for device in old.devices):
        raise ValueError("Output DMG device existed before creation; no devices were detached")
    if any(device_family(device) == root for other in after if other is not image
           for device in other.devices):
        raise ValueError("Output DMG device also belongs to another image; no devices were detached")
    return root


def run_hdiutil(arguments, timeout):
    try:
        return subprocess.run([HDIUTIL, *arguments], check=True, capture_output=True,
                              timeout=timeout).stdout
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"hdiutil {arguments[0]} timed out after {timeout} seconds; packaging stopped") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"hdiutil {arguments[0]} failed: {detail}") from error


def create_dmg(source, output, volume, run=run_hdiutil):
    source, output = Path(source).resolve(), Path(output).resolve()
    if output.suffix.lower() != ".dmg":
        raise ValueError("Output must have a .dmg suffix so hdiutil uses the exact checked path")
    before = parse_attachments(run(["info", "-plist"], 15))
    require_unattached(before, output)  # Must precede create -ov or any output deletion.
    run(["create", "-volname", volume, "-srcfolder", str(source), "-format", "UDZO",
         "-ov", str(output)], 600)
    after = parse_attachments(run(["info", "-plist"], 15))
    device = cleanup_device(before, after, output)
    if device:
        print(f"Detaching newly created, unmounted output DMG: {device}")
        run(["detach", device], 30)  # Normal detach only. Never force or retry another device.
        remaining = parse_attachments(run(["info", "-plist"], 15))
        if matching_images(remaining, output) or aliased_images(remaining, output):
            raise ValueError("Output DMG remains attached after normal detach; packaging stopped")
    run(["verify", str(output)], 120)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--volume", required=True)
    args = parser.parse_args()
    try:
        create_dmg(args.source, args.output, args.volume)
    except (ValueError, OSError, RuntimeError, plistlib.InvalidFileException) as error:
        print(f"DMG creation stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
