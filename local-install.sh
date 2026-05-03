#!/bin/bash

# Local Install Script for Shelly-ALPM
# This script builds and installs Shelly locally, similar to install.sh
# but starting from source code instead of pre-built binaries.

set -e  # Exit on any error

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Bitte als Root ausführen (sudo verwenden)."
  exit 1
fi

INSTALL_DIR="/opt/shelly"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIG="Release"

echo "=============================================="
echo "Shelly-Installationsskript lokale Installation"
echo "=============================================="
echo ""

# Check if dotnet is installed
if ! command -v dotnet &> /dev/null; then
    echo "Fehler: Das .NET SDK ist nicht installiert. Bitte installiere zuerst das .NET 10.0 SDK."
    exit 1
fi

echo "Skriptverzeichnis: $SCRIPT_DIR"
echo "Installationsverzeichnis: $INSTALL_DIR"
echo ""

# Build Shelly-Notifications
echo "Shelly-Benachrichtigungen erstellen …"
cd "$SCRIPT_DIR/Shelly-Notifications"
dotnet publish -c $BUILD_CONFIG -r linux-x64 -o "$SCRIPT_DIR/publish/Shelly-Notifications" -p:InstructionSet=x86-64
echo "Shelly – Benachrichtigungs-Build abgeschlossen."
echo ""

# Build Shelly.Gtk
echo "Building Shelly.Gtk …"
cd "$SCRIPT_DIR/Shelly.Gtk"
dotnet publish -c $BUILD_CONFIG -r linux-x64 -o "$SCRIPT_DIR/publish/Shelly.Gtk" -p:InstructionSet=x86-64
echo "Shelly.Gtk-Build abgeschlossen."
echo ""

# Build Shelly-CLI
echo "Building Shelly-CLI …"
cd "$SCRIPT_DIR/Shelly-CLI"
dotnet publish -c $BUILD_CONFIG -r linux-x64 -o "$SCRIPT_DIR/publish/Shelly-CLI" -p:InstructionSet=x86-64
echo "Shelly-CLI-Build abgeschlossen."
echo ""

# Create installation directory
echo "Installationsverzeichnis wird erstellt: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy Shelly-Notifications files
echo "Kopieren der Shelly-Benachrichtigungsdateien nach $INSTALL_DIR"
cp -r "$SCRIPT_DIR/publish/Shelly-Notifications/"* "$INSTALL_DIR/"

# Copy Shelly.Gtk files (binary is named 'shelly-ui' due to AssemblyName)
echo "Kopieren der Shelly.Gtk-Dateien nach $INSTALL_DIR"
cp -r "$SCRIPT_DIR/publish/Shelly.Gtk/"* "$INSTALL_DIR/"

# Copy Shelly-CLI binary (output is named 'shelly' due to AssemblyName)
echo "Kopieren der Shelly-CLI-Binärdatei nach $INSTALL_DIR"
cp "$SCRIPT_DIR/publish/Shelly-CLI/shelly" "$INSTALL_DIR/shelly"

# Copy the logo
echo "Copying log …"
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo.png" "$INSTALL_DIR/"

# Create symlinks in /usr/bin so commands are available on PATH
echo "Erstellen von symbolischen Links in /usr/bin …"
ln -sf "$INSTALL_DIR/shelly-ui" /usr/bin/shelly-ui
ln -sf "$INSTALL_DIR/shelly" /usr/bin/shelly
ln -sf "$INSTALL_DIR/shelly-notifications" /usr/bin/shelly-notifications

# Install icon to standard location
echo "Installationssymbol am Standardort …"
mkdir -p /usr/share/icons/hicolor/256x256/apps
mkdir -p /usr/share/icons/hicolor/symbolic/apps
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo.png" /usr/share/icons/hicolor/256x256/apps/shelly.png
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo-tray.png" /usr/share/icons/hicolor/256x256/apps/shelly-tray.png
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo-update.png" /usr/share/icons/hicolor/256x256/apps/shelly-update.png
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/flatpak-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/flatpak-symbolic.svg
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/arch-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/arch-symbolic.svg
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/shelly-updates-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/shelly-updates-symbolic.svg
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/shelly-shell-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/shelly-shell-symbolic.svg

# Create desktop entry
echo "Desktop-Eintrag erstellen"
cat <<EOF > /usr/share/applications/com.shellyorg.shelly.desktop
[Desktop Entry]
Name=Shelly
Comment=A Modern Arch Package Manager
Exec=/usr/bin/shelly-ui
Icon=shelly
Type=Application
Categories=System;Utility;
Terminal=false
EOF

echo "Creating notifications entry"
cat <<EOF > /usr/share/applications/shelly-notifications.desktop
[Desktop Entry]
Name=Shelly-Notifications
Exec=/usr/bin/shelly-notifications
Icon=shelly
Type=Application
Categories=System;Utility;
Terminal=false
EOF


# Clean up publish directory (optional - comment out to keep build artifacts)
echo "Build-Artefakte bereinigen …"
rm -rf "$SCRIPT_DIR/publish"

echo ""
echo "=========================="
echo "Installation abgeschlossen"
echo "=========================="
echo ""
echo "Du kannst jetzt:"
echo "  - GUI starten mit: shelly-ui"
echo "  - CLI starten mit: shelly"
echo "  - Benachrichtigungsdienst: shelly-notifications"
echo "  - Suche Shelly in deinem Anwendungsmenü"
echo ""
