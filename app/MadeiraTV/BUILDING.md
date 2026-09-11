# MadeiraTV — pbxproj / build configuration for the tvOS target

The iOS target in `app/Madeira.xcodeproj` is hand-maintained (objectVersion 56,
single target, no Xcode-generated files). The tvOS target `MadeiraTV` follows
the same pattern. Add it by hand or with Xcode's "New Target…" → tvOS → App —
the essential blocks below are what must be present either way.

## 1. Build settings (target `MadeiraTV`)

Applies to both Debug and Release:

```
SDKROOT                            = appletvos;
SUPPORTED_PLATFORMS                = "appletvos appletvsimulator";
TARGETED_DEVICE_FAMILY             = 3;
TVOS_DEPLOYMENT_TARGET             = 26.0;        // tvOS 26 focus API, or 18.0 to be safe
PRODUCT_BUNDLE_IDENTIFIER          = com.willfaust.madeira-tv;
PRODUCT_NAME                       = "MadeiraTV";
GENERATE_INFOPLIST_FILE            = NO;
INFOPLIST_FILE                     = MadeiraTV/Info.plist;
CODE_SIGN_ENTITLEMENTS             = MadeiraTV/MadeiraTV.entitlements;
CODE_SIGN_STYLE                    = Automatic;
SWIFT_OBJC_BRIDGING_HEADER         = "Madeira/Madeira-Bridging-Header.h";
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;                    // create an empty Asset Catalog for tvOS
SWIFT_VERSION                      = 5.0;
CLANG_CXX_LANGUAGE_STANDARD        = "gnu++20";
ENABLE_STRICT_OBJC_MSGSEND         = YES;
```

`HEADER_SEARCH_PATHS` / `LIBRARY_SEARCH_PATHS` — copy verbatim from the iOS
target (they point at `$(SRCROOT)/../FEX/...` and `$(SRCROOT)/Madeira`).

`IPHONEOS_DEPLOYMENT_TARGET` from the iOS target is ignored; only
`TVOS_DEPLOYMENT_TARGET` matters.

## 2. Sources (PBXSourcesBuildPhase)

Same list as the iOS target (`MadeiraApp.swift` EXCLUDED — replaced by the
TV app entry), plus the new TV files:

```
Madeira/LogStore.swift
Madeira/LogPattern.swift
Madeira/LogTail.swift
Madeira/FPSOverlay.swift
Madeira/EntitlementChecker.swift
Madeira/JITAllocator.c
Madeira/FEXBridge.mm
Madeira/WineServerBridge.m
Madeira/WineProcessBridge.m
Madeira/PrefixExtractor.c
Madeira/IOSDisplayShim.m
Madeira/Winios/Winios.m
Madeira/wine_stubs.c
MadeiraTV/MadeiraTVApp.swift
MadeiraTV/Models.swift
MadeiraTV/LibraryView.swift
MadeiraTV/TVRunner.swift
MadeiraTV/TVJIT.swift
MadeiraTV/GamepadManager.swift
MadeiraTV/UploadHost.swift
MadeiraTV/URLHandler.swift
```

Do NOT compile `Madeira/ContentView.swift` and `Madeira/StikJITHelper.swift`
for this target (touch/tablet UI and StikDebug UI only).

## 3. Resources, Frameworks

Resources — identical to iOS: `nls`, `aarch64-windows`, `arm64ec-windows`,
`x86_64-vcruntime`, `legal`, `prefix-template.tar.gz`, `cacert.pem`.

Frameworks — identical to iOS plus **`GameController.framework`** (System/
Library/Frameworks/GameController.framework, SDKROOT). There is no UIKit
.framework entry because the iOS target does not list it either (UIKit comes
in via the SDK default link); keep the same set of `.a`/`.tbd`.

## 4. Settings that must NOT be copied from iOS

- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` needs a real tvOS asset
  catalog, otherwise codesign fails. Create `Assets.xcassets` with
  `AppIcon` (tvOS icon set: 400×240 layered). Alternatively drop the setting
  and build with `-allowProvisioningUpdates` for dev installs.
- `TARGETED_DEVICE_FAMILY = 3` (no `1,2`).
- `UIRequiredDeviceCapabilities = [arm64]` — put in Info.plist only if Xcode
  requires it; tvOS is arm64-only anyway.

## 5. Rebuilding the emulator libraries for tvOS

The ARM `.a` archives (`libwineserver.a`, `libntdll_unix.a`, `libwin32u_unix.a`,
`libdxmt_combined.a`, `libFEXCore*.a`, …) are SDK-agnostic and do NOT need to
change, but they are currently **compiled with the iOS SDK**. Because they
target `arm64-apple-ios`, Xcode will refuse to link them into an
`arm64-apple-tvos` binary ("building for tvOS, but linking in object file built
for iOS").

This is the one Mac-only step:

1. In each `build/*/build.sh`, change the SDK selection to `appletvos`
   (the scripts already parametrise `-sdk` / `--target`):
   - `build/wineserver/build.sh`, `build/ntdll-unix/build.sh`,
     `build/win32u-unix/build.sh`, `build/dxmt-ios/build.sh`,
     `build/gnutls-ios/build.sh`, plus the FEX build (`FEX/build-ios`)
     — set `SDK=appletvos`, `ARCH=arm64`.
2. Re-run the scripts on a Mac (they produce `.a` into the same paths the
   pbxproj references, plus `libdxmt_combined.a` in `app/`).
3. Rebuild via `xcodebuild -project app/Madeira.xcodeproj -target MadeiraTV
   -sdk appletvos -configuration Debug`.

Debug on a real Apple TV: attach StikDebug (tvOS build), which grants
CS_DEBUGGED/JIT; the app then allocates the JIT pool itself (TVJIT), exactly
like the iOS flow.

## 6. Verification checklist after the port

- [ ] `xcrun dyld_info -exports ...MadeiraTV` still prints `macdrv_functions`
      (the `used` attribute in IOSDisplayShim.m must survive the tvOS link).
- [ ] JIT badge in the menu shows "debugger attached" when launched from
      StikDebug on tvOS.
- [ ] Library lists uploaded games; `curl -X POST --data-binary @G.exe
      "http://<atv>:8080/upload?name=G.exe"` lands the file in Documents/Games
      and the grid refreshes.
- [ ] `madeira://launch/<name>` from another app launches the game.
- [ ] Gamepad: right stick moves the mouse (mouse-look), left stick arrows,
      A=Enter, B=Esc; Menu returns to the library.