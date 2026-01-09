#!/bin/bash
# Fan Control Build Script

set -e

echo "Building Fan Control..."

# Build SMC utility
echo "Compiling smc_util..."
cd backend
clang -O2 -framework IOKit -o smc_util smc.c

# Build Swift app
echo "Compiling Swift app..."
cd ../swift
swiftc -o FanControl -parse-as-library FanControl.swift

# Create app bundle
echo "Creating app bundle..."
APP_DIR="../dist/Fan Control.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy files
cp FanControl "$APP_DIR/Contents/MacOS/"
cp ../backend/smc_util "$APP_DIR/Contents/Resources/"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FanControl</string>
    <key>CFBundleIdentifier</key>
    <string>com.fancontrol.app</string>
    <key>CFBundleName</key>
    <string>Fan Control</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Copy icon if exists
if [ -f "../assets/AppIcon.png" ]; then
    cp ../assets/AppIcon.png "$APP_DIR/Contents/Resources/"
fi

# Sign the app
echo "Signing app..."
codesign --force --deep --sign - "$APP_DIR"

echo "Done! App created at: $APP_DIR"
