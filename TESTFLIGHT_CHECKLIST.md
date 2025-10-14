# TestFlight Launch Checklist

**Date:** January 14, 2025
**App:** DrawEvolve - AI-Powered Drawing App

---

## Pre-Build Checklist

### Code Quality
- [x] No hardcoded API keys in repo
- [x] Cloudflare Worker proxy configured
- [x] All commits pushed to main
- [x] No debug print statements that shouldn't be there (they're fine for beta)
- [x] No "TODO" comments blocking core features

### App Configuration
- [ ] Update version number in Xcode (e.g., 1.0.0)
- [ ] Update build number in Xcode (e.g., 1)
- [ ] Check bundle identifier matches App Store Connect
- [ ] Verify deployment target (iPadOS 17+)
- [ ] Set correct signing team

### App Store Connect Setup
- [ ] App created in App Store Connect
- [ ] Bundle ID registered
- [ ] TestFlight Internal Testing group created
- [ ] App icon uploaded (1024x1024)
- [ ] Privacy policy URL ready (if required)
- [ ] Beta App Description written

### Content Review
- [ ] App name: "DrawEvolve"
- [ ] Subtitle (optional): "AI-Powered Drawing Feedback"
- [ ] Keywords: drawing, art, feedback, AI, sketch, illustration, iPad
- [ ] Screenshots prepared (iPad Pro 12.9" required)
- [ ] App Store description ready

---

## Build Steps (Xcode)

1. **Open Xcode Project**
   ```bash
   cd DrawEvolve/DrawEvolve
   open DrawEvolve.xcodeproj
   ```

2. **Select Target Device**
   - Product → Destination → Any iOS Device (arm64)

3. **Archive Build**
   - Product → Archive
   - Wait for archive to complete

4. **Validate Archive**
   - Window → Organizer
   - Select latest archive
   - Click "Validate App"
   - Fix any validation errors

5. **Upload to TestFlight**
   - Click "Distribute App"
   - Select "App Store Connect"
   - Select "Upload"
   - Wait for processing (10-30 minutes)

---

## Post-Upload Checklist

### TestFlight Setup
- [ ] Add "What to Test" notes for testers
- [ ] Enable internal testing
- [ ] Add internal testers (yourself first)
- [ ] Wait for "Ready to Test" email

### What to Test Notes (Example)
```
Welcome to DrawEvolve Beta!

This is the first TestFlight build. Please test:

CORE FEATURES:
- Drawing with brush and eraser
- Shape tools (line, rectangle, circle, polygon)
- Selection tools (rectangle select, lasso)
- Moving selected pixels (drag after selecting)
- Deleting selected pixels (may have issues - please report)
- Layers (add, delete, change opacity)
- Undo/Redo
- Save to gallery
- AI feedback (requires drawing context first)

KNOWN ISSUES:
- Delete selection button may not work correctly
- Some tools in toolbar are placeholders (magic wand, smudge, etc.)

Please report any crashes, visual bugs, or unexpected behavior!
```

---

## Common Issues & Fixes

### Build Fails
- Check provisioning profiles
- Update signing certificates
- Clean build folder (Cmd+Shift+K)

### Validation Fails
- Missing app icon
- Invalid bundle ID
- Missing required device capabilities
- Privacy usage descriptions missing

### Upload Fails
- Network timeout - retry
- App Store Connect maintenance
- Certificate/profile issues

---

## First Tester Steps

1. **Install TestFlight app** from App Store on iPad
2. **Check email** for TestFlight invitation
3. **Accept invitation** and install DrawEvolve
4. **Test core flow:**
   - Launch app
   - Fill out onboarding (subject, style)
   - Draw something
   - Try selection tools
   - Request AI feedback
   - Save to gallery
   - Create another drawing from gallery

5. **Report feedback** via TestFlight app:
   - Screenshots of issues
   - Describe steps to reproduce
   - Note device model and iPadOS version

---

## Version History

### v1.0.0 (Build 1) - Initial TestFlight
**Features:**
- Metal-accelerated drawing with pressure sensitivity
- 11 working tools (brush, eraser, shapes, fill, selection, text, etc.)
- Multi-layer support with opacity and visibility
- Undo/Redo system
- Gallery with save/load
- AI feedback with beautiful markdown rendering
- Critique history navigation
- Dark mode support
- Collapsible toolbar

**Known Limitations:**
- Delete selection may have issues
- 9 placeholder tools not yet implemented
- Zoom/pan disabled (code exists)

---

## Next Build Priorities

Based on tester feedback:
1. Fix delete selection if broken
2. Test selection pixel moving on real hardware
3. Consider removing placeholder tools or implementing them
4. Add more comprehensive onboarding/tutorial

---

## Notes

- **Target Audience:** Artists and digital illustrators on iPad
- **Unique Value:** Real-time AI feedback on artwork
- **TestFlight Goal:** Validate core features before public release
- **Beta Duration:** 2-4 weeks recommended

---

## Resources

- [Apple TestFlight Documentation](https://developer.apple.com/testflight/)
- [App Store Connect](https://appstoreconnect.apple.com/)
- [Human Interface Guidelines - iPad](https://developer.apple.com/design/human-interface-guidelines/ipados)
