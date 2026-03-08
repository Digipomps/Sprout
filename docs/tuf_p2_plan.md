# TUF P2 Plan

## Goal
Extend update verification from checksum/provenance/signature verification to full TUF metadata with rollback protection.

## Planned roles
- `root`
- `targets`
- `snapshot`
- `timestamp`

## Planned decision path
1. verify TUF root
2. verify timestamp freshness
3. verify snapshot consistency
4. verify targets metadata for artifact/channel/version
5. verify artifact hash
6. evaluate `UpdateGrantPolicy`
7. produce installation plan

## Rollback controls
- minimum version floor per artifact/channel
- reject stale timestamp metadata
- reject older target versions unless an explicit rollback grant exists
