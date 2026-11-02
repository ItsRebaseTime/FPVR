# FPVR

FPVR turns a Steam Frame VR headset (or an Android phone, or a Linux PC) into a ground-control station for a USB-connected FPV drone — live video, GPS map, telemetry, and flight input, all in one app.

Built with airsoft/milsim teams in mind: FPVR watches the drone's camera feed for people and vehicles in real time, tells your own players apart from referees by their high-vis vests, and pushes sightings straight to your team's **ATAK** map over the air. One pilot in the headset becomes real-time overwatch for the whole squad.

## What it does

- **Fly from a VR headset.** Live FPV video, a GPS map of the UAV's position, and full telemetry, composited into the headset's passthrough view — no separate monitor or ground-station laptop needed.
- **Spot people and vehicles automatically.** An on-device AI model watches the FPV feed for people, cars, trucks, and buses, drawing live bounding boxes over the video so you don't have to stare at every frame yourself.
- **Tell teammates from referees.** A configurable high-vis-vest color filter excludes referees from detections, so your overwatch feed stays about the game, not the people running it.
- **Estimate where a sighting actually is.** Using the UAV's GPS fix, altitude, and the camera's known mount angle, a detection's position on the ground is estimated and placed on the map.
- **Share sightings live over ATAK.** Detections and the UAV's own position are broadcast as CoT events to any teammate's phone running ATAK on the same network/radio — no manual reporting over voice comms.
- **Runs on what you've got.** The same core app runs on the Steam Frame (VR), a plain Android phone, or a Linux PC — pick whichever hardware fits the role.

No CPU fallback for AI detection, on purpose — it's GPU-only so it stays fast and doesn't drain the headset's battery.

## Install (Steam Frame)

[![Install with FramePort](https://img.shields.io/badge/Install%20with-FramePort-blue?style=for-the-badge)](https://frameport.app/install?manifest=https%3A%2F%2Fgithub.com%2FItsRebaseTime%2FFPVR%2Freleases%2Flatest%2Fdownload%2Fframeport-manifest.json)

1. Install [FramePort](https://github.com/spoopyghosty0/frameport) on your Steam Frame (see its own README for setup — it's the community sideloading tool for this headset).
2. Click the badge above, or open FramePort and add this manifest URL directly: `https://github.com/ItsRebaseTime/FPVR/releases/latest/download/frameport-manifest.json`
3. FramePort downloads and installs the latest release automatically. New releases are published whenever this project's `main` branch is updated — see [Development](docs/DEVELOPMENT.md#releases--ci) for how.

Prefer to build it yourself, or want Android/Linux PC builds? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Hardware

FPVR expects a USB-connected UAV setup: a UVC camera for FPV video, a serial GPS module, and an ELRS receiver for telemetry/channel data. It talks to that hardware directly — no separate ground-station radio or companion computer required beyond the USB link itself.

## Companion project: FPVBox

[**FPVBox**](https://github.com/ItsRebaseTime/FPVBox) is a companion hardware project providing ELRS, GNSS, and video receiver (VRX) functionality to the Steam Frame — or any other supported system — over USB, so FPVR has something to plug into.

## Status

What's implemented, what's been verified on real hardware, and what's still open — see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the detail behind any of these.

**Done and tested on real hardware**
- [x] UVC FPV video capture + MJPEG decode (USB webcam and a real analog FPV receiver)
- [x] NMEA GPS parsing and CRSF ELRS parsing/channel packing
- [x] AI person/vehicle detection (NCNN/Vulkan, GPU-only) running live on Steam Frame
- [x] Referee exclusion via vest-color matching
- [x] Detection overlay (bounding boxes + color-coded legend) on the FPV feed, coordinate-mapping bug fixed and verified on-device
- [x] ATAK CoT bridge over UDP multicast (position + AI sightings, real packets received and validated)
- [x] VR shell (`shell_vr_steamframe`) running on real Steam Frame hardware
- [x] Android shell on a Pixel 10 Pro: USB serial, UVC via raw usbfs, phone GNSS fallback
- [x] Settings UI (centered layout, vest color wheel, sliders)

**Done, but only lightly tested / partially verified**
- [ ] CDC-ACM serial GPS/ELRS on Android (only a UVC-class device has been attached during Android testing so far)
- [ ] The `uvcvideo`-absent fallback capture path specifically on Steam Frame (verified on Android and two other real UVC devices; the test Steam Frame unit currently has `uvcvideo` bound, so the true "no kernel driver at all" condition on that device hasn't been exercised live)
- [ ] Passthrough IR/RGB/Black toggling (best-effort — Valve hasn't published an API to tell stock monochrome passthrough apart from the third-party color camera)
- [ ] Ground-plane distance/GPS estimation for a detection (implemented; real-world accuracy against a known offset not yet logged)
- [ ] Devcontainer + GitHub Actions release pipeline (just added — this is its first real run)

**Not done yet**
- [ ] TAK-server TCP/TLS unicast, for a teammate's phone with no shared local network/radio (local UDP multicast only for now — explicit v1 scope decision)
- [ ] Hexagon NPU (QNN) backend as an alternative to Vulkan (stretch goal; Vulkan is what actually ships)
- [ ] Verifying OpenXR controller button/action bindings against the real Steam Frame controllers (currently Godot's default action map)

## Development

Architecture, build instructions, platform status, and the AI detection pipeline are documented in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
