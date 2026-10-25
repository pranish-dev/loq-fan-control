// LOQFanMon - Fan and Thermal hardware monitor for Lenovo LOQ 15IAX9 (Hackintosh).
// Maps the EC memory page at 0xFE0B0000, publishes telemetry to the IORegistry and
// provides EC fan speed / Full Fan control.
//
// v0.1.1 changes (safety):
//   - RPM requests are clamped to [MIN_RAW, MAX_RAW]; no more 8-bit wrap-around.
//   - Fan commands are serialized with a lock (timer and setProperties can't collide).
//   - Longer, sleeping waits (firmware's ERCD allows ~1 s); errors are returned to the caller.
//   - WATCHDOG: if manual fan control is active and no command arrives for
//     WATCHDOG_TICKS seconds, the kext hands control back to the firmware (Auto).
//   - Auto is restored when the kext stops.
//   - IOLog only on failures/watchdog (no log spam at 2 commands per second).
//
// Offsets come from the DSDT/SSDT3 (EC0 scope):
//   ECMM  @ 0xFE0B0400 : GZ44 at +0x0B, CTMP at +0xB0
//   FANR  @ 0xFE0B0500 : FA1S at +0x04, FA2S at +0x2B
//   ECCD  @ 0xFE0B0400+0x222 : ECTB/ECTE bits; ECMD +0x22B, EDT1..EDT5 +0x22C..0x230
//   EFAN  @ 0xFE0B0F00 : fan table, FFON at +0xB6
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSData.h>
#include <mach/mach_types.h>

#define PAGE_PHYS   0xFE0B0000ULL
#define PAGE_LEN    0x1000
#define ECMM_OFF    0x400
#define GZ44_OFF    (ECMM_OFF + 0x0B)
#define CTMP_OFF    (ECMM_OFF + 0xB0)
#define FANR_OFF    0x500
#define FANR_LEN    0x80
#define EFAN_OFF    0xF00
#define EFAN_LEN    0x100
#define FA1S_OFF    (FANR_OFF + 0x04)
#define FA2S_OFF    (FANR_OFF + 0x2B)
#define FFON_OFF    (EFAN_OFF + 0xB6)

#define ECCD_OFF    0x600
#define ECCD_TRIG   (ECCD_OFF + 0x22)  // 0x622: bit 0 ECTB (busy), bit 1 ECTE (execute)
#define ECCD_CMD    (ECCD_OFF + 0x2B)  // 0x62B: ECMD
#define ECCD_DT1    (ECCD_OFF + 0x2C)  // 0x62C: EDT1
#define ECCD_DT2    (ECCD_OFF + 0x2D)  // 0x62D: EDT2

// Safety limits (raw byte = RPM / 100). 19 = 1900 RPM (lowest firmware speed measured), 50 = 5000 RPM.
#define MIN_RAW          19
#define MAX_RAW          50
#define WATCHDOG_TICKS   5      // seconds without a command before reverting to firmware Auto

class LOQFanMon : public IOService {
    OSDeclareDefaultStructors(LOQFanMon)
    IOMemoryDescriptor   *mdesc   = nullptr;
    IOMemoryMap          *mmap    = nullptr;
    IOTimerEventSource   *timer   = nullptr;
    IOWorkLoop           *wl      = nullptr;
    volatile uint8_t     *base    = nullptr;
    IOLock               *ecLock  = nullptr;
    volatile bool         manualActive = false;
    volatile uint32_t     staleTicks   = 0;

    void tick(IOTimerEventSource *sender);
    void publishRange(const char *key, uint32_t off, uint32_t len);
    bool dispatchECCommand(uint8_t cmd, uint8_t dt1, uint8_t dt2);
    bool restoreAuto();
    bool setFan(uint8_t fanCmd, uint32_t rpm);
    bool setMaxFan();
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn setProperties(OSObject *properties) override;
};

#define super IOService
OSDefineMetaClassAndStructors(LOQFanMon, IOService)

void LOQFanMon::publishRange(const char *key, uint32_t off, uint32_t len) {
    uint8_t buf[0x100];
    if (len > sizeof(buf)) len = sizeof(buf);
    for (uint32_t i = 0; i < len; i++) buf[i] = base[off + i];   // byte-wise MMIO reads
    OSData *d = OSData::withBytes(buf, len);
    if (d) { setProperty(key, d); d->release(); }
}

// Mirrors the firmware's ERCD handshake. Serialized by ecLock.
bool LOQFanMon::dispatchECCommand(uint8_t cmd, uint8_t dt1, uint8_t dt2) {
    if (!base || !ecLock) return false;
    IOLockLock(ecLock);

    // 1. Wait up to ~500 ms for the EC to be idle
    int ms = 500;
    while ((base[ECCD_TRIG] & 0x03) != 0 && ms > 0) { IOSleep(1); ms--; }
    if (ms == 0) {
        IOLockUnlock(ecLock);
        IOLog("LOQFanMon: EC busy timeout (cmd 0x%02x)\n", cmd);
        return false;
    }

    base[ECCD_TRIG] |= 0x01;              // ECTB
    base[ECCD_CMD] = cmd;
    base[ECCD_DT1] = dt1;
    base[ECCD_DT2] = dt2;
    base[ECCD_DT2 + 1] = 0;
    base[ECCD_DT2 + 2] = 0;
    base[ECCD_DT2 + 3] = 0;
    base[ECCD_TRIG] |= 0x02;              // ECTE (execute)

    // 2. Wait up to ~1 s for completion (firmware allows 100 x 10 ms)
    ms = 1000;
    while ((base[ECCD_TRIG] & 0x02) != 0 && ms > 0) { IOSleep(1); ms--; }

    base[ECCD_TRIG] &= ~0x01;             // clear ECTB
    bool ok = (ms > 0);
    IOLockUnlock(ecLock);
    if (!ok) IOLog("LOQFanMon: EC command 0x%02x/0x%02x timed out\n", cmd, dt1);
    return ok;
}

// Hand fan control back to the firmware.
bool LOQFanMon::restoreAuto() {
    if (!base) return false;
    bool ok = dispatchECCommand(0x46, 0x84, 0);
    base[FFON_OFF] &= ~0x01;
    setProperty("FFON", (uint64_t)(base[FFON_OFF] & 0x01), 8);
    if (ok) { manualActive = false; staleTicks = 0; }   // on failure the watchdog retries next tick
    return ok;
}

// fanCmd: 0x85 = CPU fan, 0x86 = GPU fan. rpm == 0 means "restore Auto".
bool LOQFanMon::setFan(uint8_t fanCmd, uint32_t rpm) {
    if (rpm == 0) return restoreAuto();
    uint32_t raw = rpm / 100;
    if (raw < MIN_RAW) raw = MIN_RAW;
    if (raw > MAX_RAW) raw = MAX_RAW;
    bool ok = dispatchECCommand(0x46, fanCmd, (uint8_t)raw);
    if (ok) { manualActive = true; staleTicks = 0; }
    return ok;
}

bool LOQFanMon::setMaxFan() {
    base[FFON_OFF] |= 0x01;
    bool a = dispatchECCommand(0x46, 0x85, MAX_RAW);
    bool b = dispatchECCommand(0x46, 0x86, MAX_RAW);
    setProperty("FFON", (uint64_t)(base[FFON_OFF] & 0x01), 8);
    if (a || b) { manualActive = true; staleTicks = 0; }
    return a && b;
}

void LOQFanMon::tick(IOTimerEventSource *sender) {
    if (base) {
        publishRange("FANR", FANR_OFF, FANR_LEN);
        publishRange("EFAN", EFAN_OFF, EFAN_LEN);
        setProperty("FA1S", (uint64_t)base[FA1S_OFF], 8);
        setProperty("FA2S", (uint64_t)base[FA2S_OFF], 8);

        // GZ44 in ECMM: 0=Balanced (White), 1=Performance (Red), 2=Quiet (Blue), 3=Custom, 7=Extreme
        uint8_t pmod = (base[GZ44_OFF] >> 5) & 0x07;
        setProperty("PMOD", (uint64_t)pmod, 8);
        setProperty("CTMP", (uint64_t)base[CTMP_OFF], 8);
        setProperty("FFON", (uint64_t)(base[FFON_OFF] & 0x01), 8);
        setProperty("MANU", (uint64_t)(manualActive ? 1 : 0), 8);

        // WATCHDOG: no command from the app for WATCHDOG_TICKS seconds -> firmware Auto
        if (manualActive) {
            if (++staleTicks >= WATCHDOG_TICKS) {
                IOLog("LOQFanMon: watchdog - no fan command for %d s, restoring firmware control\n", WATCHDOG_TICKS);
                restoreAuto();
            }
        }
    }
    sender->setTimeoutMS(1000);
}

bool LOQFanMon::start(IOService *provider) {
    if (!super::start(provider)) return false;

    ecLock = IOLockAlloc();
    if (!ecLock) return false;

    mdesc = IOMemoryDescriptor::withPhysicalAddress(PAGE_PHYS, PAGE_LEN, kIODirectionInOut);
    if (!mdesc) { IOLog("LOQFanMon: withPhysicalAddress failed\n"); return false; }
    mmap = mdesc->createMappingInTask(kernel_task, 0, kIOMapAnywhere | kIOMapInhibitCache);
    if (!mmap) { IOLog("LOQFanMon: map failed\n"); mdesc->release(); mdesc = nullptr; return false; }
    base = (volatile uint8_t *)mmap->getVirtualAddress();

    wl = getWorkLoop();
    timer = IOTimerEventSource::timerEventSource(this,
        OSMemberFunctionCast(IOTimerEventSource::Action, this, &LOQFanMon::tick));
    if (!wl || !timer || wl->addEventSource(timer) != kIOReturnSuccess) {
        IOLog("LOQFanMon: timer setup failed\n");
        return false;   // stop() will clean up
    }
    timer->setTimeoutMS(100);
    registerService();
    IOLog("LOQFanMon: started (fan control with %d s watchdog)\n", WATCHDOG_TICKS);
    return true;
}

void LOQFanMon::stop(IOService *provider) {
    if (timer) { timer->cancelTimeout(); if (wl) wl->removeEventSource(timer); timer->release(); timer = nullptr; }
    if (base && manualActive) restoreAuto();      // never leave fans in manual mode
    if (mmap)  { mmap->release();  mmap  = nullptr; }
    if (mdesc) { mdesc->release(); mdesc = nullptr; }
    base = nullptr;
    if (ecLock) { IOLockFree(ecLock); ecLock = nullptr; }
    super::stop(provider);
}

IOReturn LOQFanMon::setProperties(OSObject *properties) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, properties);
    if (!dict) return super::setProperties(properties);
    if (!base) return kIOReturnNotReady;

    // SetMaxFan: 1 = Full Fan (5000 RPM both fans), 0 = back to firmware Auto
    OSNumber *maxFan = OSDynamicCast(OSNumber, dict->getObject("SetMaxFan"));
    if (maxFan) {
        bool ok = maxFan->unsigned32BitValue() ? setMaxFan() : restoreAuto();
        return ok ? kIOReturnSuccess : kIOReturnTimeout;
    }

    // SetCPUFanRPM / SetGPUFanRPM: RPM (clamped to MIN_RAW*100 .. MAX_RAW*100), 0 = Auto
    OSNumber *cpuRPM = OSDynamicCast(OSNumber, dict->getObject("SetCPUFanRPM"));
    if (cpuRPM) return setFan(0x85, cpuRPM->unsigned32BitValue()) ? kIOReturnSuccess : kIOReturnTimeout;

    OSNumber *gpuRPM = OSDynamicCast(OSNumber, dict->getObject("SetGPUFanRPM"));
    if (gpuRPM) return setFan(0x86, gpuRPM->unsigned32BitValue()) ? kIOReturnSuccess : kIOReturnTimeout;

    return super::setProperties(properties);
}

// ---- kmod boilerplate (needed because we build without Xcode) ----
extern "C" {
kern_return_t _start(kmod_info_t *ki, void *data);
kern_return_t _stop(kmod_info_t *ki, void *data);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(com.local.LOQFanMon, "0.1.0", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t  *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
}
