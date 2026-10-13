#!/usr/bin/env python3
"""Exercise a Sprout executable with synthetic state.

Verify publisher signatures before testing downloaded releases. For local source
builds, retain source/build provenance separately; this runner verifies neither.

Default checks are offline. --expired-discovery-domain explicitly permits one
public discovery GET per attempt (no identity registration) and expects expired
trust to be rejected. Never point this test at an existing identity directory.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--expired-discovery-domain")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if not os.access(binary, os.X_OK):
        parser.error("binary must be executable")
    results = args.results.resolve()
    results.mkdir(mode=0o700, parents=True, exist_ok=False)
    checks = []

    def invoke(name, arguments, answers="", env=None):
        started = time.monotonic()
        record = {"case": name}
        checks.append(record)
        try:
            process = subprocess.run([str(binary), *arguments], input=answers,
                                     capture_output=True, text=True, timeout=60, env=env)
            record.update(exit_code=process.returncode,
                          seconds=round(time.monotonic() - started, 4))
            (results / (name + ".stdout.txt")).write_text(process.stdout)
            (results / (name + ".stderr.txt")).write_text(process.stderr)
            return process, record
        except subprocess.TimeoutExpired:
            record.update(status="failed", reason="timeout",
                          seconds=round(time.monotonic() - started, 4))
            raise AssertionError(name + " timed out") from None

    def require(record, condition, reason):
        if not condition:
            record.update(status="failed", reason=reason)
            raise AssertionError(record["case"] + ": " + reason)
        record["status"] = "passed"

    try:
        with tempfile.TemporaryDirectory(prefix="sprout-runtime-") as temporary:
            state = Path(temporary)
            env = dict(os.environ, XDG_STATE_HOME=str(state / "xdg"))
            p, rec = invoke("doctor", ["doctor", "--json"], env=env)
            require(rec, p.returncode == 0, "doctor failed")
            report = json.loads(p.stdout)
            require(rec, report["cryptography"] == "passed" and report["network"] == "not_contacted"
                    and report["identityStorage"] == "not_read_or_created"
                    and report["channelReadiness"] == "not_verified", "diagnostic overstated readiness")
            require(rec, not (state / "xdg").exists(), "doctor created identity state")
            marker = "SYNTHETIC_REDACTION_MARKER"
            p, rec = invoke("invalid_domain_redaction",
                            ["onboard", "--domain", "https://user:" + marker + "@example.org"], env=env)
            require(rec, p.returncode != 0 and marker not in p.stdout + p.stderr
                    and "invalidInput" in p.stderr and not (state / "xdg").exists(),
                    "invalid domain echoed sensitive input or created state")
            p, rec = invoke("refusal", [], "nei\n", env)
            require(rec, p.returncode == 0 and not (state / "xdg").exists(), "refusal created state")
            p, rec = invoke("eof", ["onboard", "--state-dir", str(state / "eof")], env=env)
            require(rec, p.returncode == 0 and not (state / "eof").exists(), "EOF created state")
            p, rec = invoke("offline", [], "ja\nny\n\n\n\nsenere\nja\n", env)
            require(rec, p.returncode == 0, "offline dialogue failed")
            root = state / "xdg/haven/sprout"
            seed = root / "identities/local.sprout.invalid/keys/ed25519.seed"
            original = seed.read_bytes()
            p, rec = invoke("resume", ["chat"], "ja\n/status\nsenere\nja\n", env)
            require(rec, p.returncode == 0 and seed.read_bytes() == original
                    and "Forrige kontroll: localOnly" in p.stdout
                    and not (root / "scaffold-identities").exists(), "resume changed identity or authority")
            p, rec = invoke("consent_bypass", ["onboard", "--yes", "--state-dir", str(state / "invalid")], env=env)
            require(rec, p.returncode != 0 and not (state / "invalid").exists(), "blanket consent accepted")
            (root / "onboarding.json").write_text("corrupt")
            p, rec = invoke("corrupt_state", [], "ja\n", env)
            require(rec, p.returncode != 0 and seed.read_bytes() == original
                    and "ikke slett" in p.stdout.lower(), "corrupt identity silently replaced")
            if args.expired_discovery_domain:
                network_state = state / "expired-discovery"
                first_seed = None
                for attempt in range(2):
                    answers = ("ja\nny\n\n\n\n" + args.expired_discovery_domain + "\nja\nja\n"
                               if attempt == 0 else "ja\nja\nja\n")
                    p, rec = invoke("expired_discovery_" + str(attempt + 1),
                                    ["onboard", "--state-dir", str(network_state)], answers, env)
                    require(rec, p.returncode != 0 and "trustDescriptorExpired" in p.stderr
                            and "tillitsbeskrivelse er utloept" in p.stdout,
                            "expired trust did not produce the actionable refusal")
                    profile = json.loads((network_state / "onboarding.json").read_text())
                    require(rec, not profile["trustedAdminKeys"] and profile["lastOutcome"] == "localOnly"
                            and not (network_state / "scaffold-identities").exists(),
                            "discovery granted trust or created domain identity")
                    current = (network_state / "identities/local.sprout.invalid/keys/ed25519.seed").read_bytes()
                    require(rec, first_seed is None or current == first_seed, "retry replaced local identity")
                    first_seed = current
    except (AssertionError, OSError, ValueError, KeyError) as error:
        if checks:
            checks[-1].update(status="failed", reason=str(error))
        print("FAIL:", error)
        return_code = 1
    else:
        return_code = 0
        print("PASS:", len(checks), "CLI runtime checks")
    finally:
        summary = {"schema": "sprout.cli-runtime-test.v1", "platform": platform.platform(),
                   "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                   "publisher_verification": "not_performed_by_test; verify_downloaded_releases_separately",
                   "checks": checks}
        (results / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
