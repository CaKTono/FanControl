# Fan Control for macOS - Development Log

## Project Overview

A native macOS fan control application built from scratch with Swift/SwiftUI, featuring real-time temperature monitoring, customizable fan profiles, and menu bar integration.

**Repository:** https://github.com/CaKTono/FanControl  
**Developer:** Calvin Kristianto  
**Development Period:** January 9-13, 2026

---

## Features Implemented

### Core Features
- ✅ **Fan Control Profiles**: Auto, Silent, 50%, 75%, Max, Custom
- ✅ **Custom Mode**: Percentage-based sliders for individual or all fans
- ✅ **Real-time Sensor Display**: CPU cores, GPU cores, system temperatures
- ✅ **Menu Bar Integration**: Customizable display (CPU temp, GPU temp, RPM, percentage)
- ✅ **Launch at Login**: ServiceManagement integration
- ✅ **One-time Authorization**: Privileged helper installation

### Technical Implementation

#### Backend (`smc.c`)
- Direct SMC (System Management Controller) access via IOKit
- Dynamic sensor discovery for Apple Silicon (M1/M2/M3/M4)
- Fan speed control using F0Md (mode), F0Mn (minimum), F0Tg (target) keys
- Temperature reading with sp78 and flt data types
- Virtual "Average CPU" and "Hottest CPU" sensors

#### Frontend (`FanControl.swift`)
- SwiftUI-based interface with HSplitView layout
- SMCManager singleton for centralized state management  
- MenuBarController for NSStatusItem management
- AppSettings for UserDefaults persistence
- Background command execution to prevent UI blocking

---

## Development Timeline

### Day 1 (January 9, 2026)
1. **Initial Setup**
   - Created project structure: `backend/smc.c`, `swift/FanControl.swift`
   - Implemented basic SMC read/write functions
   - Built SwiftUI interface with fan cards and sensor list

2. **Sensor Display**
   - Added comprehensive sensor keys for Apple Silicon
   - Implemented sensor caching to prevent flickering
   - Added temperature color coding (green → orange → red)

3. **Fan Profiles**
   - Created FanProfile enum with preset speeds
   - Implemented Custom mode with percentage sliders
   - Added "All Fans" linked slider

4. **Helper Installation**
   - Built privileged helper tool (`smc_util`)
   - Implemented setuid root installation via NSAppleScript
   - Added Settings menu with Install/Reinstall/Uninstall options

### Day 2 (January 10, 2026)
5. **Menu Bar Integration**
   - Created MenuBarController with NSStatusItem
   - Added profile switching from menu bar
   - Implemented customizable display modes:
     - CPU Temperature
     - GPU Temperature
     - Fan RPM
     - Fan Percentage
     - CPU Temp + RPM
     - CPU Temp + Fan %

6. **Fan Percentage Calculation Fix**
   - Changed from (rpm - minRpm) / (maxRpm - minRpm) to rpm / maxRpm
   - 0% now represents 0 RPM, 100% represents max RPM

7. **Zero RPM Warning**
   - Added confirmation dialog when setting fans below 5%
   - Warning message about overheating risks

8. **GitHub Repository**
   - Created README.md, LICENSE (MIT), .gitignore, build.sh
   - Published to https://github.com/CaKTono/FanControl
   - Created v1.0 release with pre-built app bundle

### Day 3 (January 12-13, 2026)
9. **M4 Fan Wake Investigation**
   - Attempted to replicate Macs Fan Control's ability to wake dormant fans
   - Tested F0Md, F0Mn, F0Tg with continuous retries (failed)
   - Tested persistent SMC connection with 100ms loop (failed)
   - Tested F0Fc (Fan Force Control) key - write-protected
   - Tested FS! (Force bits) key - doesn't exist on M4
   - **Conclusion:** Apple M4 firmware blocks third-party fan wake from 0 RPM

10. **Cleanup & Final Release**
    - Removed experimental "Keep Trying" wake feature
    - Simplified setFanSpeed to single command without retry
    - Published v1.1 release

---

## Architecture

```
FanControl/
├── backend/
│   ├── smc.c          # C implementation for SMC access
│   └── smc_util       # Compiled binary (installed to /Library/PrivilegedHelperTools/)
├── swift/
│   ├── FanControl.swift   # Complete SwiftUI app (single file)
│   └── FanControl         # Compiled binary
├── assets/
│   └── AppIcon.png    # Custom app icon
├── releases/
│   └── FanControl-v1.1.zip
├── README.md
├── LICENSE
├── build.sh
└── .gitignore
```

---

## Key SMC Keys Used

| Key | Type | Description |
|-----|------|-------------|
| FNum | ui8 | Number of fans |
| F0Ac | flt/fpe2 | Fan 0 actual RPM |
| F0Mn | flt/fpe2 | Fan 0 minimum RPM |
| F0Mx | flt/fpe2 | Fan 0 maximum RPM |
| F0Md | ui8 | Fan 0 mode (0=auto, 1=manual) |
| F0Tg | flt/fpe2 | Fan 0 target RPM |
| Tp0* | sp78 | CPU temperature sensors |
| Tg0* | sp78 | GPU temperature sensors |

---

## Known Limitations

1. **M4 Fan Wake from 0 RPM**: Apple's firmware prevents third-party apps from starting fans that are completely off. Fans can only be controlled after macOS activates them.

2. **No Code Signing**: App requires ad-hoc signing (`codesign --force --deep --sign -`)

3. **Helper Permissions**: Requires administrator password once to install privileged helper

---

## Build Instructions

```bash
# Build SMC utility
cd backend
clang -O2 -framework IOKit -o smc_util smc.c

# Build Swift app
cd ../swift
swiftc -o FanControl -parse-as-library FanControl.swift

# Or use build script
./build.sh
```

---

## Releases

| Version | Date | Notes |
|---------|------|-------|
| v1.0 | 2026-01-10 | Initial release |
| v1.1 | 2026-01-13 | Simplified fan control, removed wake retry |

---

## Credits

- Inspired by [Macs Fan Control](https://crystalidea.com/macs-fan-control) and [Stats](https://github.com/exelban/stats)
- SMC access based on Apple's IOKit framework
