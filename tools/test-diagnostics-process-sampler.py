#!/usr/bin/env python3
"""Exercise bounded diagnostics sampling, including an owned native fixture.

Only the temporary fixture is passed to /usr/bin/sample. No game is launched or
sampled. Build products and fixture samples are removed on completion.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="nightcity-sampler-tests-") as directory:
        scratch = pathlib.Path(directory)
        source = scratch / "fixture.c"
        source.write_text("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n")
        fixture = scratch / "owned-fixture"
        subprocess.run(["xcrun", "clang", "-o", str(fixture), str(source)], check=True)
        tests = scratch / "sampler-tests"
        subprocess.run([
            "xcrun", "swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos12",
            str(ROOT / "launcher/Sources/DiagnosticsProcessSampler.swift"),
            str(ROOT / "tools/DiagnosticsProcessSamplerTests.swift"), "-o", str(tests),
        ], check=True)
        subprocess.run([str(tests), str(scratch), str(fixture)], check=True, timeout=35)


if __name__ == "__main__":
    main()
