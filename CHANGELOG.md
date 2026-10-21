# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

## [1.0.0] - 2026-10-21

### Added
- `Install-HEVC.ps1`: build-aware installer for the free HEVC Video Extensions
  (`Microsoft.HEVCVideoExtension`, Store ID `9N4WGH0Z6VHQ`).
- Reads `TargetDeviceFamily MinVersion` out of each candidate `.appxbundle`
  manifest and installs the newest bundle the running build supports, fixing
  `0x80073CFD` on Windows 10 / Windows 11 up to 24H2.
- Candidate priority: local folder -> download cache -> latest GitHub release
  assets -> Microsoft delivery CDN.
- Authenticode verification (`O=Microsoft Corporation`) before install.
- Architecture-aware payload selection (`x64` / `x86` / `arm64` / `neutral`).
- Machine profiling: OS build + UBR, edition, locale, GPU, estimated hardware
  HEVC decode support, N-edition warning.
- `-Diagnose`, `-Force`, `-Uninstall`, `-AllUsers`, `-Offline`, `-BundlePath`,
  `-CacheDir`, `-LogFile`, `-TimeoutSec`.
- Exit codes for scripting: 0 / 10 / 20 / 21 / 30 / 40.
- `Install-HEVC.cmd` wrapper for double-click use.
- CI (syntax + PSScriptAnalyzer) and tag-driven release workflow.
- Release assets: script bundle, both compatible `.appxbundle` builds, checksums.
