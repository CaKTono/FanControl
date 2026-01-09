# Fan Control for macOS

A lightweight, native fan control application for macOS with support for Apple Silicon (M1/M2/M3/M4) and Intel Macs.

## Features

- 🎛️ **Profile Presets**: Auto, Silent, 50%, 75%, Max, Custom
- 🎚️ **Custom Control**: Percentage-based sliders for individual or all fans
- 📊 **Sensor Monitoring**: Real-time CPU, GPU, and system temperatures
- 🔧 **Menu Bar**: Quick access with customizable display (temp, RPM, %)
- 🚀 **Launch at Login**: Start automatically with your Mac
- 🔐 **One-time Authorization**: Install helper once, no more password prompts

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac

## Installation

### Option 1: Download Release
1. Download `FanControl.zip` from [Releases](../../releases)
2. Extract and move `Fan Control.app` to `/Applications`
3. Open the app and click **Settings > Install Helper** (one-time setup)

### Option 2: Build from Source
```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/FanControl.git
cd FanControl

# Build the SMC utility
cd backend
clang -O2 -framework IOKit -o smc_util smc.c

# Build the Swift app
cd swift
swiftc -o FanControl -parse-as-library FanControl.swift

# Create app bundle
./build.sh
```

## Usage

1. **Launch** Fan Control from Applications
2. **Install Helper** (Settings > Install Helper) - one-time setup
3. **Select a Profile** or use **Custom** mode for manual control
4. **Enable Menu Bar** in Settings for quick access

### Profiles

| Profile | Description |
|---------|-------------|
| Auto | Let macOS manage fans automatically |
| Silent | Minimum fan speed for quiet operation |
| 50% | Half speed, balanced noise/cooling |
| 75% | Higher speed for demanding tasks |
| Max | Maximum cooling |
| Custom | Manual control with sliders |

## Menu Bar Options

- CPU Temperature
- GPU Temperature  
- Fan RPM
- Fan Percentage
- CPU Temp + RPM
- CPU Temp + Fan %

## Troubleshooting

### Fans not responding
- Ensure helper is installed (Settings > Install/Reinstall Helper)

### Sensors showing 0°
- Reinstall helper to update sensor list

### App won't open
```bash
codesign --force --deep --sign - "/Applications/Fan Control.app"
```

## License

MIT License

## Credits

- Inspired by [Macs Fan Control](https://crystalidea.com/macs-fan-control) and [Stats](https://github.com/exelban/stats)
