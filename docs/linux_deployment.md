# Linux Deployment

## Supported baseline
- Target OS: Ubuntu 22.04 `x86_64`
- Supported binaries:
  - `sprout-linux-x86_64`
  - `sprout-updater-linux-x86_64`
- No Docker is required for build, verification or deployment.
- Current scope is bootstrap, contract verification, release verification and operator-managed install/update.

## Explicit non-goals in the current baseline
- `sprout-macos`
- iOS runtime
- implicit self-update from `sprout`
- full Linux WSS streaming parity

`WSSClient` is still not implemented for non-Apple runtime parity, so Linux support must be understood as a narrow CLI/server bootstrap baseline.

## Expected release assets
For a Linux release, expect at minimum:
- `sprout-linux-x86_64`
- `sprout-updater-linux-x86_64`
- `release-manifest-linux-x86_64.json`
- `SHA256SUMS-linux-x86_64.b64url`
- `sprout-linux-x86_64.spdx.json`
- optional cosign `.sig` / `.pem` files
- optional `SHA256SUMS-linux-x86_64.b64url.asc`

## Verify before install
Example local verification:
```bash
bash Scripts/build_release_bundle.sh dist linux-x86_64
bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-linux-x86_64.b64url
```

After downloading a published bundle, verify the checksum file and artifacts before moving them into place.

Direct updater verification:
```bash
./sprout-updater-linux-x86_64 verify-bundle \
  --artifact-path ./sprout-linux-x86_64 \
  --checksum-file ./SHA256SUMS-linux-x86_64.b64url
```

## Recommended filesystem layout
- binaries: `/opt/sprout/bin`
- configuration: `/etc/sprout`
- mutable state: `/var/lib/sprout`
- logs: `/var/log/sprout`

Suggested install:
```bash
sudo install -d -m 0755 /opt/sprout/bin /etc/sprout /var/lib/sprout /var/log/sprout
sudo install -m 0755 sprout-linux-x86_64 /opt/sprout/bin/sprout
sudo install -m 0755 sprout-updater-linux-x86_64 /opt/sprout/bin/sprout-updater
```

## Service account
Create a dedicated service user and keep mutable state away from the binary path.

Example:
```bash
sudo useradd --system --home /var/lib/sprout --shell /usr/sbin/nologin sprout
sudo chown -R sprout:sprout /var/lib/sprout /var/log/sprout
```

## Example systemd unit
```ini
[Unit]
Description=Sprout HAVEN bootstrap service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sprout
Group=sprout
WorkingDirectory=/var/lib/sprout
EnvironmentFile=-/etc/sprout/sprout.env
ExecStart=/opt/sprout/bin/sprout bootstrap join --domain example.haven.local --purpose bootstrap.join_scaffold --goal "Join scaffold and register identity" --interests haven.core.bootstrap,haven.core.bridge --starter /etc/sprout/starter_auth_payload.signed.json --catalog /etc/sprout/bridge_catalog.json --porthole cli
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/sprout /var/log/sprout

[Install]
WantedBy=multi-user.target
```

## Update model
- `sprout` does not self-update.
- `sprout-updater` verifies bundles and can produce a policy-gated install plan.
- Operators replace binaries explicitly after verification.
- `UpdateGrantPolicy` remains default deny.

## Operational notes
- Prefer immutable release artifacts and explicit rollback procedures.
- Pin trusted resolver keys and scaffold admin trust roots in deployment config where applicable.
- Keep keystore files and audit logs under restricted ownership.
- If Linux needs streaming bridge traffic later, treat WSS parity as a separate hardening milestone, not as an implicit extension of this baseline.
