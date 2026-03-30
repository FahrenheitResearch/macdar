# macdar iOS

Metal-native NEXRAD radar for iPhone.

## Build

### Option A: Xcode (recommended)
1. Install [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Generate project: `cd ios && xcodegen generate`
3. Open `macdar.xcodeproj` in Xcode
4. Select your development team in Signing & Capabilities
5. Build and run on device (Metal requires real hardware)

### Option B: Manual Xcode project
1. Create new iOS App project in Xcode
2. Add all files from `ios/macdar/` and the shared sources from `src/`
3. Set bridging header to `macdar/Bridge/macdar-Bridging-Header.h`
4. Add header search paths: `../src` and `../src/metal`
5. Compile `.cpp` files as Objective-C++ with `-x objective-c++ -fobjc-arc`
6. Link: Metal.framework, libz, libbz2, libcurl

## Requirements
- iOS 17.0+
- iPhone with Apple Silicon (A11+)
- Xcode 15+
