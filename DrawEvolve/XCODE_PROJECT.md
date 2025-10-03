# Xcode Project Setup

This file explains how to create the `DrawEvolve.xcodeproj` file, which is required to build the iOS app.

## Current Status

The repository contains all Swift source files but **does not include an Xcode project file** yet. You have three options to create it:

---

## Option 1: Create Manually in Xcode (Recommended)

This is the standard approach for iOS app development.

### Steps:

1. **Open Xcode** on your Mac

2. **Create New Project**:
   - File → New → Project
   - Select **iOS** → **App** → Next

3. **Configure Project**:
   - **Product Name**: `DrawEvolve`
   - **Team**: Select your Apple Developer team
   - **Organization Identifier**: `com.yourcompany` (must match Bundle ID in App Store Connect)
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Storage**: None (we use AppStorage)

4. **Save Location**:
   - Navigate to: `/workspaces/DrawEvolve/DrawEvolve/`
   - Click **Create**
   - Xcode will generate `DrawEvolve.xcodeproj`

5. **Delete Generated Files**:
   - Delete the auto-generated `DrawEvolveApp.swift` and `ContentView.swift`
   - We already have these in the `App/` folder

6. **Add Existing Source Files**:
   - Right-click on the DrawEvolve folder in Xcode navigator
   - Select **Add Files to "DrawEvolve"**
   - Navigate to the source folders and add:
     - `App/`
     - `Features/`
     - `Services/`
     - `Utilities/`
   - **Important**: Uncheck "Copy items if needed" (files are already in place)
   - Select **Create groups**
   - Click **Add**

7. **Configure Target Settings**:
   - Select the project in the navigator
   - Select **DrawEvolve** target → **General** tab
   - Set **Deployment Target**: `iOS 16.0` or higher
   - Set **Bundle Identifier**: Must match App Store Connect (e.g., `com.yourcompany.drawevolve`)
   - **Display Name**: `DrawEvolve`

8. **Add Frameworks**:
   - Scroll to **Frameworks, Libraries, and Embedded Content**
   - PencilKit should auto-link (iOS 13.0+)
   - If not, click **+** → Search "PencilKit" → Add

9. **Configure Info.plist**:
   - Select **Info** tab
   - Add custom property:
     - **Key**: `NSPhotoLibraryAddUsageDescription`
     - **Type**: String
     - **Value**: `DrawEvolve needs permission to save your drawings to your Photos library.`

10. **Add Privacy Manifest**:
    - The `PrivacyInfo.xcprivacy` file is already in `App/`
    - Ensure it's included in the target (check in File Inspector)

11. **Configure Scheme** (Important for CI):
    - Product → Scheme → Manage Schemes
    - Select **DrawEvolve** scheme
    - Check **Shared** checkbox
    - Click **Close**
    - This creates `.xcodeproj/xcshareddata/xcschemes/DrawEvolve.xcscheme`

12. **Test Build**:
    - Select a simulator or device
    - Press `Cmd + B` to build
    - Press `Cmd + R` to run
    - App should launch successfully

13. **Commit to Git**:
    ```bash
    git add DrawEvolve/DrawEvolve.xcodeproj
    git add DrawEvolve/DrawEvolve.xcodeproj/xcshareddata
    git commit -m "Add Xcode project and shared schemes"
    git push
    ```

---

## Option 2: Create via Command Line (Advanced)

This option uses Swift Package Manager (requires additional setup).

### Steps:

1. **Create Package.swift** (not included yet):
   ```swift
   // swift-tools-version:5.9
   import PackageDescription

   let package = Package(
       name: "DrawEvolve",
       platforms: [.iOS(.v16)],
       products: [
           .library(name: "DrawEvolve", targets: ["DrawEvolve"])
       ],
       targets: [
           .target(
               name: "DrawEvolve",
               path: "DrawEvolve"
           )
       ]
   )
   ```

2. **Generate Xcode Project**:
   ```bash
   cd /workspaces/DrawEvolve/DrawEvolve
   swift package generate-xcodeproj
   ```

3. **Limitations**:
   - Does not auto-configure Info.plist
   - Requires manual setup of app target
   - Not recommended for standard iOS apps

**Recommendation**: Use Option 1 instead.

---

## Option 3: CI-Only (No Local Xcode Project)

Build directly from source files using `xcodebuild` without a project file.

### Requirements:

- Modify `.github/workflows/ios-testflight.yml` to use source-based build
- Requires advanced `xcodebuild` configuration
- More complex to maintain

**Recommendation**: Not recommended. Create project locally (Option 1) and commit it.

---

## After Creating the Project

Once you've created the Xcode project:

1. **Verify Structure**:
   ```
   DrawEvolve/
   ├── DrawEvolve.xcodeproj/
   │   ├── project.pbxproj
   │   └── xcshareddata/
   │       └── xcschemes/
   │           └── DrawEvolve.xcscheme  # Must exist for CI
   ├── DrawEvolve/
   │   ├── App/
   │   ├── Features/
   │   ├── Services/
   │   └── Utilities/
   ```

2. **Test CI Build**:
   - Push a test tag: `git tag v0.1.0-test && git push origin v0.1.0-test`
   - Monitor GitHub Actions workflow
   - Verify build succeeds

3. **Configure Export Options**:
   - Create `DrawEvolve/ExportOptions.plist` (see README.md)
   - Required for CI to export IPA

4. **Enable TestFlight Upload**:
   - Once App Store Connect is configured
   - Uncomment upload step in workflow
   - See README.md for details

---

## Troubleshooting

### "No such file or directory: DrawEvolve.xcodeproj"
- The project hasn't been created yet
- Follow Option 1 above to create it

### "Scheme 'DrawEvolve' is not shared"
- Go to: Product → Scheme → Manage Schemes
- Check **Shared** for the DrawEvolve scheme
- Commit the `xcshareddata` folder

### "Cannot find 'PKCanvasView' in scope"
- Add PencilKit framework to target
- Ensure deployment target is iOS 13.0+

### "Missing Info.plist"
- Xcode should auto-generate Info.plist
- Add required keys manually in Info tab

### Build succeeds locally but fails in CI
- Ensure scheme is shared (see above)
- Verify all source files are added to target
- Check deployment target matches CI

---

## Why This File Exists

The Xcode project file (`.xcodeproj`) is **not included in the initial repository** because:

1. It's binary/XML that doesn't diff well in version control
2. Different developers may have different Xcode versions
3. It's typically generated once and committed

This file serves as **instructions** for creating the project file when needed.

Once created and committed, this file can be deleted or kept for reference.
