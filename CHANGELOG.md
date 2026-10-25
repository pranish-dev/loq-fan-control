# Changelog

## 0.3.0 — 2026-10-25

- Redesigned UI: gauge-style dashboard with temperature-colored arc gauges, segmented
  mode picker in the header, status chips (mode, power mode, kext connection),
  emergency-mode banner, restyled curve editor with gradient fill and glow,
  richer menu-bar dropdown with live readings.
- New app icon (rendered programmatically, `app/icon/make-icon.swift`).
- Menu bar shows a compact temperature/RPM readout next to the fan icon.
- App builds cleanly with Xcode Command Line Tools (Swift 6.1.2); kext builds cleanly
  and its bundle version was bumped to 0.2.0.
- All 27 `LOQCoreChecks` validation checks pass.

## 0.2.0

- Hardened kext: 5-second watchdog restoring firmware Auto, `MANU` IORegistry property,
  clamped RPM range (1900–5000), serialized EC commands. [unverified on hardware]
- SwiftUI app: custom fan curve editor, gradual ramping, temperature smoothing,
  emergency override, fail-safes, menu bar item. [unverified end-to-end on hardware]

## 0.1.0

- Initial kext: EC memory-mapped reads (`FA1S`, `FA2S`, `PMOD`, `CTMP`, `FFON`) and
  fan commands via the firmware EC handshake (`0x46` + `0x85`/`0x86`/`0x84`).
  Verified on hardware: register reads, fixed speed, max fan.
