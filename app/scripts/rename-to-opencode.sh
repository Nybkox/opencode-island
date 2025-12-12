#!/bin/bash
# Rename OpenCodeIsland to OpenCodeIsland
# Run from project root: ./scripts/rename-to-opencode.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Phase 1: Renaming Files and Directories ==="
echo ""

# Step 1: Rename files inside OpenCodeIsland/ first (before renaming the directory)
echo "Renaming Swift files..."

# App
if [ -f "OpenCodeIsland/App/OpenCodeIslandApp.swift" ]; then
    git mv "OpenCodeIsland/App/OpenCodeIslandApp.swift" "OpenCodeIsland/App/OpenCodeIslandApp.swift"
    echo "  Renamed OpenCodeIslandApp.swift"
fi

# Resources
if [ -f "OpenCodeIsland/Resources/OpenCodeIsland.entitlements" ]; then
    git mv "OpenCodeIsland/Resources/OpenCodeIsland.entitlements" "OpenCodeIsland/Resources/OpenCodeIsland.entitlements"
    echo "  Renamed OpenCodeIsland.entitlements"
fi

# Delete old Python hook (will be replaced by TypeScript plugin)
if [ -f "OpenCodeIsland/Resources/opencode-island-state.py" ]; then
    git rm "OpenCodeIsland/Resources/opencode-island-state.py"
    echo "  Removed opencode-island-state.py"
fi

# Services
if [ -f "OpenCodeIsland/Services/Session/ClaudeSessionMonitor.swift" ]; then
    git mv "OpenCodeIsland/Services/Session/ClaudeSessionMonitor.swift" "OpenCodeIsland/Services/Session/OpenCodeSessionMonitor.swift"
    echo "  Renamed ClaudeSessionMonitor.swift"
fi

# UI
if [ -f "OpenCodeIsland/UI/Views/ClaudeInstancesView.swift" ]; then
    git mv "OpenCodeIsland/UI/Views/ClaudeInstancesView.swift" "OpenCodeIsland/UI/Views/OpenCodeInstancesView.swift"
    echo "  Renamed ClaudeInstancesView.swift"
fi

# Step 2: Rename xcscheme
echo ""
echo "Renaming Xcode scheme..."
if [ -f "OpenCodeIsland.xcodeproj/xcshareddata/xcschemes/OpenCodeIsland.xcscheme" ]; then
    git mv "OpenCodeIsland.xcodeproj/xcshareddata/xcschemes/OpenCodeIsland.xcscheme" "OpenCodeIsland.xcodeproj/xcshareddata/xcschemes/OpenCodeIsland.xcscheme"
    echo "  Renamed OpenCodeIsland.xcscheme"
fi

# Step 3: Rename main directories (do this last)
echo ""
echo "Renaming main directories..."

if [ -d "OpenCodeIsland.xcodeproj" ]; then
    git mv "OpenCodeIsland.xcodeproj" "OpenCodeIsland.xcodeproj"
    echo "  Renamed OpenCodeIsland.xcodeproj -> OpenCodeIsland.xcodeproj"
fi

if [ -d "OpenCodeIsland" ]; then
    git mv "OpenCodeIsland" "OpenCodeIsland"
    echo "  Renamed OpenCodeIsland/ -> OpenCodeIsland/"
fi

echo ""
echo "=== Phase 1 Complete ==="
echo ""
echo "Next: Run Phase 2 to update file contents"
