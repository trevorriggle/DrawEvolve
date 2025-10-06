#!/bin/bash

echo "🎨 DrawEvolve Setup Script"
echo "=========================="
echo ""

# Check if Config.plist exists
if [ -f "DrawEvolve/Config/Config.plist" ]; then
    echo "✅ Config.plist already exists"
else
    echo "📝 Creating Config.plist from template..."
    cp DrawEvolve/Config/Config.example.plist DrawEvolve/Config/Config.plist
    echo "⚠️  Please edit DrawEvolve/Config/Config.plist and add your OpenAI API key"
    echo "   Open it with: open DrawEvolve/Config/Config.plist"
fi

echo ""
echo "📦 Project Structure:"
echo "   - DrawEvolve.xcodeproj (Xcode project)"
echo "   - DrawEvolve/ (source code)"
echo "   - README.md (documentation)"
echo ""

# Check if we're on macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "✅ Running on macOS"

    # Check if Xcode is installed
    if command -v xcodebuild &> /dev/null; then
        echo "✅ Xcode is installed"
        xcodebuild -version
        echo ""
        echo "🚀 Ready to build!"
        echo ""
        echo "Next steps:"
        echo "  1. Add your OpenAI API key to DrawEvolve/Config/Config.plist"
        echo "  2. Open DrawEvolve.xcodeproj in Xcode"
        echo "  3. Select a simulator or device"
        echo "  4. Press Cmd+R to run"
        echo ""
        read -p "Would you like to open the project in Xcode now? (y/n) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            open DrawEvolve.xcodeproj
        fi
    else
        echo "❌ Xcode not found. Please install Xcode from the Mac App Store."
    fi
else
    echo "⚠️  Not running on macOS"
    echo "   This project requires Xcode and macOS to build."
    echo "   Make sure to transfer this code to your Mac Mini."
fi

echo ""
echo "📚 For more information, see README.md"
