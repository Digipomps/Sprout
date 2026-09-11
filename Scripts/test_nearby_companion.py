#!/usr/bin/env python3
"""Exercise installed macOS sprout lookup without radio, HAVEN or person data."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="sprout-nearby-path-") as scratch:
        root = Path(scratch)
        install = root / "install"
        launch = root / "bin"
        install.mkdir()
        launch.mkdir()
        shutil.copy2(binary, install / "sprout")
        helper = install / "haven-nearby"
        helper.write_text("#!/bin/sh\nprintf '%s\\n' synthetic-companion-found \"$@\"\n")
        helper.chmod(0o700)
        (launch / "sprout").symlink_to(install / "sprout")
        env = dict(os.environ)
        env.pop("SPROUT_NEARBY_HELPER", None)

        def check(name, invocation, directory, override=None, expected=0):
            current = dict(env, PATH=str(directory) + ":/usr/bin:/bin")
            if override is not None:
                current["SPROUT_NEARBY_HELPER"] = override
            result = subprocess.run([invocation, "nearby", "--help"], cwd=root,
                                    env=current, capture_output=True, text=True, timeout=10)
            assert result.returncode == expected, (name, result.returncode, result.stderr)
            if expected == 0:
                assert result.stdout.splitlines() == ["synthetic-companion-found", "--help"], (name, result.stdout)
            else:
                assert "synthetic-companion-found" not in result.stdout
            print("PASS:", name)

        check("absolute executable", str(install / "sprout"), launch)
        check("executable found through PATH", "sprout", install)
        check("launch symlink found through PATH", "sprout", launch)
        check("explicit relative companion", "sprout", launch, "install/haven-nearby")
        check("missing explicit companion fails closed", "sprout", launch, "missing-helper", 2)


if __name__ == "__main__":
    main()
