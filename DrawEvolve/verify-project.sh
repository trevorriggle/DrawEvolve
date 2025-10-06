#!/bin/bash

echo "🔍 DrawEvolve Project Verification"
echo "=================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_file() {
    if [ -f "$1" ]; then
        echo -e "${GREEN}✓${NC} $1"
        return 0
    else
        echo -e "${RED}✗${NC} $1 (MISSING)"
        return 1
    fi
}

check_dir() {
    if [ -d "$1" ]; then
        echo -e "${GREEN}✓${NC} $1/"
        return 0
    else
        echo -e "${RED}✗${NC} $1/ (MISSING)"
        return 1
    fi
}

echo "📂 Project Structure:"
check_dir "DrawEvolve.xcodeproj"
check_dir "DrawEvolve"
check_dir "DrawEvolve/Views"
check_dir "DrawEvolve/Models"
check_dir "DrawEvolve/Services"
check_dir "DrawEvolve/Config"
check_dir "DrawEvolve/Assets.xcassets"
echo ""

echo "📄 Core Files:"
check_file "DrawEvolve/DrawEvolveApp.swift"
check_file "DrawEvolve/Views/ContentView.swift"
check_file "DrawEvolve/Views/PromptInputView.swift"
check_file "DrawEvolve/Views/DrawingCanvasView.swift"
check_file "DrawEvolve/Views/FeedbackOverlay.swift"
check_file "DrawEvolve/Models/DrawingContext.swift"
check_file "DrawEvolve/Services/OpenAIManager.swift"
echo ""

echo "⚙️  Configuration:"
check_file "DrawEvolve/Info.plist"
check_file "DrawEvolve/Config/Config.example.plist"
check_file "DrawEvolve.xcodeproj/project.pbxproj"
echo ""

echo "📝 Documentation:"
check_file "README.md"
check_file "QUICKSTART.md"
check_file "PROJECT_SUMMARY.md"
check_file ".gitignore"
echo ""

# Check if Config.plist exists (should NOT be in git)
if [ -f "DrawEvolve/Config/Config.plist" ]; then
    echo -e "${YELLOW}⚠${NC}  Config.plist exists (good for local dev, but shouldn't be in git)"
else
    echo -e "${YELLOW}ℹ${NC}  Config.plist not found (you'll need to create it from Config.example.plist)"
fi
echo ""

# Count Swift files
swift_files=$(find DrawEvolve -name "*.swift" | wc -l)
echo "📊 Statistics:"
echo "   Swift files: $swift_files"
echo "   Total lines: $(find DrawEvolve -name "*.swift" -exec wc -l {} + | tail -1 | awk '{print $1}')"
echo ""

# Check if .gitignore is protecting secrets
if grep -q "Config.plist" .gitignore; then
    echo -e "${GREEN}✓${NC} .gitignore is protecting Config.plist"
else
    echo -e "${RED}✗${NC} WARNING: Config.plist is not in .gitignore!"
fi
echo ""

echo "✅ Project verification complete!"
echo ""
echo "Next steps:"
echo "  1. Copy Config.example.plist to Config.plist"
echo "  2. Add your OpenAI API key to Config.plist"
echo "  3. Open DrawEvolve.xcodeproj in Xcode"
echo "  4. Build and run (Cmd+R)"
