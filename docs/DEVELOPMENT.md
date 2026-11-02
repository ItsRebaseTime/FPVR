# Development

Implementation notes, architecture, build instructions, and current platform status. See the main [README](../README.md) for what FPVR is and who it's for.

## Layout

- `core/` — GDExtension (C++/godot-cpp) native library: USB device discovery (serial + UVC, USB-only), NMEA GPS parsing, CRSF ELRS parsing/channel-packing, UVC capture, NCNN-based AI detection (`core/src/ai/`), ATAK CoT message building. Build with `cd core && scons platform=linux target=template_debug` (desktop x86_64), `arch=arm64` added for Steam Frame — see Status below and the VSCode tasks.
  - UVC capture has two backends behind one interface: `UvcDriver` (V4L2, kernel-driven) is always preferred when a `/dev/videoX` node exists. `UvcUsbfsDriver` (direct `USBDEVFS_*` ioctls on the raw usbfs fd — the same mechanism libusb/libuvc use) is the fallback: the *only* option on Android (no built-in UVC support at all), and an automatic fallback on any Linux target — including Steam Frame — when a UVC device is on the bus but no `uvcvideo` kernel module is bound to it (`UsbDeviceRegistry` detects this via a sysfs walk). `HardwareHub` picks automatically and surfaces a warning in the Video and Telemetry windows when running on the fallback, since it's less latency-stable than the kernel driver.
  - `core/src/ai/` — NCNN/Vulkan inference engine running a NanoDet-Plus person/vehicle detector (no CPU fallback — see Status). `inference_engine.{h,cpp}` wraps NCNN load/run; `nanodet_decoder.{h,cpp}` decodes raw model output to boxes; `referee_filter.{h,cpp}` does HSV-based high-vis-vest matching to exclude referees from sightings.
- `app/` — Godot 4.7 project.
  - `core_services/` — shared GDScript glue: `hardware_hub.gd` (autoload; owns device discovery + live drivers, read by every window/shell — picks a Linux or Android backend automatically), `android_usb_source.gd` (Android's serial-port equivalent, backed by the plugin below), `control_mapper.gd` (flight input → CRSF channels), `passthrough_controller.gd` (IR/RGB/Black toggle), `settings.gd` (persisted settings), `detection_service.gd` (background AI-detection loop), `detection_geolocation.gd` (ground-plane position estimation for a detection).
  - `input/` — interchangeable flight-control sources: `steamframe_controller_input.gd` (OpenXR motion controllers), `generic_gamepad_input.gd` (BT/USB HID gamepad).
  - `windows/` — the four shared window scenes (video, GPS/UAV map, telemetry/status, settings), used unmodified by every shell (each shell toggles which settings rows are relevant to it).
  - `xr/` — VR-only pieces: XR rig, SubViewport-on-a-quad window wrapper, grab dispatcher, `detection_overlay*` (AI bounding-box + legend overlay on the FPV feed).
  - `bridge/` — `atak_bridge.gd`, shares position/telemetry and AI-detected sightings with ATAK on a companion phone as CoT over UDP.
  - `shells/` — `shell_linux_pc` (flat, windows side by side — primary dev/iteration target), `shell_vr_steamframe` (XR shell with grabbable windows + flight control + passthrough toggle), `shell_android_phone` (flat, tabbed, safe-area-aware).
  - `android/build/src/main/java/org/fpvr/plugin/FpvrPlugin.java` — the Android-platform plugin (see below).
  - `bootstrap.gd`/`.tscn` — the actual main scene; picks the right shell at runtime (VR shell only if an OpenXR session actually initializes, else the phone shell on Android, else the Linux/PC shell), so one APK works correctly on both a Steam Frame and a plain phone.

## AI Detection

NanoDet-Plus-m_416 (Apache-2.0), run through NCNN's Vulkan backend — GPU-only by design, no CPU fallback: the Steam Frame's CPU cores aren't powerful enough to run this at a usable rate, and sustained CPU inference would drain battery far faster than the GPU path. Detects people and (optionally) cars/trucks/buses from the 80-class COCO label set. A configurable HSV color match against a chosen high-vis-vest color excludes referees from sightings. Detections are drawn as an overlay on the FPV feed (bounding boxes + a color-coded legend), optionally geolocated via a ground-plane intersection using the UAV's GPS/altitude/heading plus the camera's mount tilt and FOV, and forwarded to ATAK as CoT events over the existing UDP multicast bridge.

## Building

### Devcontainer (recommended for the Steam Frame / release build)

`.devcontainer/` defines a Docker image with the Godot editor, export templates, and the zig-based ARM64/glibc-2.17 cross-toolchain preinstalled — the exact same image used by `.github/workflows/release.yml`. Open the repo in VSCode with the Dev Containers extension and it builds automatically, or run the equivalent manually:

```bash
docker build -t fpvr-build .devcontainer
docker run --rm -v "$PWD:/workspace" -w /workspace fpvr-build bash -c '
    core/scripts/build_ncnn_arm64.sh
    core/scripts/build_core_arm64.sh template_debug
    cd app && godot --headless --export-debug "Steam Frame (Linux ARM64)" builds/steamframe/fpvr.arm64
'
```

### Native build (any target)

See `.vscode/tasks.json` for the full set of build/export/run tasks (desktop Linux x86_64, Android arm64, and Steam Frame arm64). In short:

- `core/` is a GDExtension built with `scons` (`platform=linux` or `platform=android`, `arch=arm64` for Steam Frame/Android).
- Steam Frame specifically cross-compiles via `zig cc`/`zig c++` targeting glibc 2.17, not the host's own `aarch64-linux-gnu-gcc` — see the comment on the "Core: Build (Linux ARM64 - Steam Frame)" task for why (the host's own newer glibc produces a binary that fails to `dlopen` on real hardware).
- `app/` exports via `godot --headless --export-debug/--export-release <preset> <output>` once the matching core library is built.

### Releases / CI

Pushing to `main` runs `.github/workflows/release.yml`: it builds the Steam Frame target inside the devcontainer image, packages it, and publishes a GitHub Release with a [FramePort](https://github.com/spoopyghosty0/frameport) install manifest. Day-to-day work happens on `dev`; merging `dev` into `main` is what cuts a release.

## Status

- Verified end-to-end on this dev machine: USB auto-discovery, NMEA GPS parsing, CRSF ELRS parsing + channel packing (against hand-built reference frames), UVC capture + JPEG decode (against a real USB webcam), ATAK CoT bridge (real UDP packets received and validated), AI detection (NCNN/Vulkan on real Steam Frame hardware, person + vehicle classes, referee-vest exclusion), all four window scenes, and all three shells booting cleanly.
- `shell_vr_steamframe` and AI detection have both been run and iterated on real Steam Frame hardware, including live field-testing with the FPV camera. Controller button/action names follow Godot's default OpenXR action map and should be checked against actual Steam Frame controller bindings if something feels off.
- **Android, tested live on a Pixel 10 Pro**:
  - Fixed an initial black-screen bug (the export preset was forcing OpenXR mode, which waits forever for a session a plain phone can never start) via the `bootstrap` runtime shell-selection described above.
  - Fixed the phone UI being clipped by the screen's rounded corners / too small to tap comfortably (safe-area-aware margins + larger touch targets in `shell_android_phone`).
  - Built `FpvrPlugin`, a Godot v2 Android plugin (Java), because stock Android blocks the raw `/dev` access the Linux backend uses (confirmed via repeated SELinux denials in testing). It exposes USB device enumeration/permission/CDC-ACM serial I/O via `UsbManager`, raw usbfs access for UVC (see below), and the phone's own built-in GNSS via `LocationManager`. `HardwareHub` picks this backend automatically on Android behind the same interface the Linux `SerialPort`/`UvcDriver` paths use, so `GpsDriver`/`ElrsDriver`/MJPEG-decode parsing is untouched — only the transport differs. When both the phone's internal GNSS and a USB GPS are present, whichever reports better accuracy wins.
  - **UVC video capture works on Android**, verified live against a real USB analog FPV receiver (not just a webcam): `UvcUsbfsDriver` (core) parses the raw UVC descriptors Android hands up, does the Probe/Commit negotiation, and streams isochronous URBs via direct `USBDEVFS_SUBMITURB`/`REAPURBNDELAY` ioctls on the raw fd — the same mechanism libusb/libuvc use on desktop Linux. Decoded MJPEG frames render in the Video window exactly like the Linux path. Getting here required finding and fixing three non-obvious platform bugs (all confirmed via on-device logcat, not guessed): Android won't show the USB permission dialog for a video-class device without `CAMERA` permission also granted; it drops a second permission-dialog request if one is already showing (now serialized through a queue in the plugin); and `PendingIntent.getBroadcast()` with `FLAG_MUTABLE` throws for an implicit intent on API 34+ (fixed via `setPackage()`) — that exception was being silently swallowed by Godot's JNI dispatch layer, invisible until a try/catch was added around the call directly. A fourth issue (raw `USBDEVFS_CLAIMINTERFACE` failing `EBUSY` even as the first attempt) was worked around by claiming the interface via Android's own `UsbDeviceConnection.claimInterface()` Java API before handing the fd to native code.
  - The CDC-ACM serial path (GPS/ELRS) has not yet been exercised against real serial hardware — only a UVC-class device was attached during Android testing so far.
  - Building the Android plugin requires Gradle's custom-build path: `godot --headless --path app --install-android-build-template` (installs the template into `app/android/`), `gradle_build/use_gradle_build=true` in `export_presets.cfg` (already set), and a JDK the Gradle version actually supports — the system default here was JDK 27, too new for Gradle 8.11.1 ("Unsupported class file major version 71"); pinned via `org.gradle.java.home` in `app/android/build/gradle.properties` to a JDK 21 install.
- Passthrough IR/RGB/Black toggling is implemented as best-effort: Valve has not published an API to distinguish stock monochrome passthrough from the third-party Arcturus color camera, so both currently issue the same OpenXR alpha-blend call.
- **Steam Frame's current OS doesn't ship the `uvcvideo` kernel module**, so `/dev/videoX` never appears for an attached UVC device there. `HardwareHub` detects this automatically (via a sysfs walk for USB video-class interfaces with no `video4linux` child) and falls back to `UvcUsbfsDriver`, with a warning shown in the Video and Telemetry windows. V4L2 is always preferred when available, including if `uvcvideo` is manually installed (as on this project's test Steam Frame unit) — kernel-driven capture is lower-latency and far more hardened against device quirks than the in-app driver.
- **Steam Frame runs real Linux/SteamOS on an ARM64 (Snapdragon) SoC — not Android.** Neither the Android APK nor the x86_64 Linux build is correct for it; it needs its own export preset, **`"Steam Frame (Linux ARM64)"`** (`app/export_presets.cfg` preset 2), built from a GDExtension cross-compiled for `platform=linux arch=arm64`. See the Building section above for the cross-compile approach and why the host's own `aarch64-linux-gnu-gcc` doesn't work.
