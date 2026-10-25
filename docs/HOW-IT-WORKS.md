# How it works

These details were read from the laptop's ACPI tables (DSDT and the Lenovo Gamezone
SSDT) and confirmed by measurement. Offsets are for the LOQ 15IAX9 firmware used during
development and may differ on other models or BIOS versions.

## EC memory window

The EC is exposed as plain memory at physical address `0xFE0B0000` (one 4 KiB page).
The kext maps it and polls it once a second.

| Item | Address | Notes |
|---|---|---|
| CPU fan speed (`FA1S`) | `0xFE0B0504` | RPM = byte x 100 |
| GPU fan speed (`FA2S`) | `0xFE0B052B` | RPM = byte x 100 |
| Power mode (`GZ44`) | `0xFE0B040B` bits 5-7 | 0 Balanced, 1 Performance, 2 Quiet, 3 Custom, 7 Extreme |
| CPU temperature (`CTMP`) | `0xFE0B04B0` | fallback temperature source |
| Full Fan flag (`FFON`) | `0xFE0B0FB6` bit 0 | 1 = firmware full speed |

Fan RPM units were verified against LenovoLegionToolkit readings (Quiet 1900/2200,
Performance 2600/2900).

## EC command interface

Fan commands use the same handshake as the firmware's `ERCD` ACPI method:

| Register | Address |
|---|---|
| Trigger (bit 0 ECTB busy, bit 1 ECTE execute) | `0xFE0B0622` |
| Command (`ECMD`) | `0xFE0B062B` |
| Data 1 / Data 2 | `0xFE0B062C` / `0xFE0B062D` |

Commands (first byte `0x46`):

| Data 1 | Meaning |
|---|---|
| `0x85` | set CPU fan speed (data 2 = RPM / 100) |
| `0x86` | set GPU fan speed (data 2 = RPM / 100) |
| `0x84` | restore firmware (Auto) control |

## Safety

- Requests are clamped to 19..50 (1900-5000 RPM) in the kext.
- Commands are serialized with a lock and the kext waits up to 1 s per command.
- A 5-second watchdog restores Auto if commands stop arriving.
- The kext cannot take the firmware's own ACPI mutex, so a firmware EC command issued at
  exactly the same moment could collide. This is expected to be rare.
- The kext has no privilege check: any local process can send fan requests (within the
  clamped range).

## Interface between kext and app

The kext publishes `FA1S`, `FA2S`, `FANR`, `EFAN`, `PMOD`, `CTMP`, `FFON` and `MANU`
as IORegistry properties. The app sends requests with `IORegistrySetCFProperty`:
`SetCPUFanRPM`, `SetGPUFanRPM` (RPM, 0 = Auto) and `SetMaxFan` (1 = Full Fan, 0 = Auto).
