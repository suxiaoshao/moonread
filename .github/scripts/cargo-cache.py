"""Pair Cargo source mtimes and verified UniFFI inputs with the CI cache."""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time


CARGO_INPUTS = (
    "crates", ".cargo", "Cargo.toml", "Cargo.lock", "rust-toolchain", "rust-toolchain.toml",
    "flake.nix", "flake.lock",
    # The Rust metadata tests include the published schema and examples.
    "docs/site/static/schema/moonread-metadata-v1.schema.json",
    "docs/site/static/skills/moonread-metadata/examples",
)
UNIFFI_CONFIG = (
    ".github/workflows/ci.yml", ".github/scripts/cargo-cache.py", ".gitattributes",
    "ios/Configuration.xcconfig", "ios/Rust.xcconfig", "ios/Moonread.xcodeproj",
    "ios/Packages/MoonreadCoreBindings",
)
RECORD = Path("target/ci-source-inputs-v1.json")


def tracked_inputs(pathspecs):
    names = subprocess.check_output(["git", "ls-files", "-z", "--", *pathspecs])
    identities, mtimes = {}, {}
    for name in names.split(b"\0"):
        if not name:
            continue
        path = Path(os.fsdecode(name))
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"Expected a regular tracked file: {path}")
        identities[str(path)] = [
            stat.S_IMODE(info.st_mode), hashlib.sha256(path.read_bytes()).hexdigest(),
        ]
        mtimes[str(path)] = info.st_mtime_ns
    return identities, mtimes


def record(key):
    # Record only the checkout that passed the regular Cargo and Xcode checks.
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--", *CARGO_INPUTS, *UNIFFI_CONFIG], check=True)
    cargo, mtimes = tracked_inputs(CARGO_INPUTS)
    uniffi, _ = tracked_inputs(UNIFFI_CONFIG)
    RECORD.write_text(json.dumps({
        "key": key, "cargo": cargo, "mtimes": mtimes, "uniffi": uniffi,
        "recorded_at": time.time_ns(),
    }))


def restore(key):
    saved = json.loads(RECORD.read_text())
    if not isinstance(saved, dict):
        raise ValueError("Invalid CI source record")
    now = time.time_ns()
    recorded_at = saved.get("recorded_at")
    if saved.get("key") != key or type(recorded_at) is not int or not 0 < recorded_at < now:
        raise ValueError("CI source record does not match the restored cache")

    previous, mtimes, verified = (saved.get(name) for name in ("cargo", "mtimes", "uniffi"))
    if not all(isinstance(field, dict) for field in (previous, mtimes, verified)):
        raise ValueError("Invalid Cargo cache inputs")
    if previous.keys() != mtimes.keys() or not all(
        type(value) is int and 0 < value <= recorded_at for value in mtimes.values()
    ):
        raise ValueError("Invalid Cargo source mtimes")

    cargo, _ = tracked_inputs(CARGO_INPUTS)
    uniffi, _ = tracked_inputs(UNIFFI_CONFIG)
    restored = 0
    for name, identity in cargo.items():
        # A changed file must be newer than the cached build, even when this
        # run checked out its sources before the cache writer built its copy.
        mtime = mtimes[name] if previous.get(name) == identity else now
        path = Path(name)
        os.utime(path, ns=(path.stat().st_atime_ns, mtime), follow_symlinks=False)
        restored += mtime != now
    print(f"Restored {restored} of {len(cargo)} Cargo input mtimes")

    if cargo == previous and uniffi == verified:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("uniffi-verified=true\n")


if __name__ == "__main__":
    mode, key = sys.argv[1:]
    if mode == "record":
        record(key)
    elif mode == "restore":
        try:
            restore(key)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f"::notice::No usable Cargo cache source record: {error}")
    else:
        raise SystemExit(f"Unknown mode: {mode}")
