# RestReminder

> A macOS menu bar app for eye care and rest breaks. It slips "blink, look away, stand up" into your day **without hijacking your attention**, and turns your daily screen habits into a report you can actually read.

[![Platform](https://img.shields.io/badge/macOS-13%2B%20Apple%20Silicon-1a73e8)](https://github.com/Zephyr-777/RestReminder)
[![Language](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-34a853)](LICENSE)

🌏 [中文说明](README.md)

![Menu](docs/images/menu.jpg)

---

## Why

Most break reminders **pop a window at you**. You hit "later", and it pops again.

The problem is frequency. Anything that appears every 15 minutes is 30+ forced interruptions a day. By day three it has stopped being a reminder and become noise — and once you start dismissing it on reflex, the whole mechanism is dead.

So the design premise here is: **a reminder should not occupy attention, only peripheral vision.**

Three things follow from that:

1. **The primary channel is a blinking eye in the menu bar.** It blinks, it dims as time passes. A glance out of the corner of your eye is enough — no reading, no clicking.
2. **A break walks you through the motions instead of announcing itself.** The overlay lasts 15 seconds and moves through four animated steps.
3. **It makes "when you forgot to rest" visible as data.** One report a day. No judgement, just the numbers.

---

## Features

### 🌱 Micro-break — every 15 min, 15 s, four steps

| Step | Time | Do | Why |
|---|---|---|---|
| 1 | 0 – 2.5s | **Squeeze eyes shut for 2s** | Full lid closure pumps the meibomian glands |
| 2 | 2.5 – 6s | **Open slowly, blink gently** | Spreads the lipid layer — a complete tear-film refresh |
| 3 | 6s – 4s left | **Look 6+ meters away** | Lets the ciliary muscle release |
| 4 | **Last 4 seconds** | **"Remember to blink"** (icon blinks twice) | The moment you return to content is exactly when you forget |

Step 4 sits at the end on purpose. The first three steps are about *stopping*; the last one is about *coming back*. Put at the beginning, it would be spoken to closed eyes.

![Micro-break step 4](docs/images/micro-break-blink.jpg)

> Duration is configurable (10 / 15 / 20 s). The closing step always takes the last 4 seconds but never starts before second 8 — otherwise the "look away" step would be squeezed to half a second at the 10 s setting.

### ☕️ Long break — every 45 min, a breathing screen

A full-screen breathing animation (5 / 8 / 15 s), then a **seamlessly looping glow screen** or a real display sleep. It targets a different failure: you think you've sat for an hour, and it's been four.

![Long break](docs/images/long-break.jpg)

The loop isn't a captured video — it's rendered frame by frame so that petals, glow and particles all align to a 15-second cycle. See [`docs/design/`](docs/design/).

### 😌 Blink rhythm — every 5 min, one small motion

This is the highest-frequency channel (12 times an hour), so it **never pops a window, never makes a sound, never covers content**:

- **The eye blinks once** in the menu bar: open → half-closed and dimmed → open, 0.8 s. Seeing an eye close triggers a mirror-neuron blink reflex far faster than reading "please blink".
- **The icon slowly dries out** between blinks — fading from full to 60% over the last 30% of the interval. The icon *is* the progress bar: catch it looking grey, blink, and it recovers. No reminder object required.

Optional extra: a very faint cyan breathing at the screen edges (off by default). Worth noting one trap — the first version "brightened" the edges in white, which is completely invisible on a white page (pure white + 5% white is still pure white). A tint from the accent color works on both light and dark backgrounds.

### 📊 Daily report

The app records what it is doing once per second, per day. A Python script renders that into a single self-contained HTML file (no CDN, works offline): screen time KPIs, an hourly intensity chart, a time-composition donut, rest compliance bars, and an eye-strain risk index with a 14-day trend.

With Full Disk Access granted, it also reads Apple's own Screen Time data (`knowledgeC.db`) and shows app-level breakdowns side by side with this tool's own measurement. The days where the two disagree wildly are usually the days you were staring without touching the keyboard.

### 🚶 Presence detection

It doesn't trust the keyboard alone — reading, video calls and long documents all look like "idle hands". Four signals are combined: display sleep, screen lock / console session, **display-sleep assertions** (something is playing full-screen → still counts as screen time), and input idle time.

---

## Install

Requires **macOS 13+ on Apple Silicon** and Xcode Command Line Tools (`xcode-select --install`).
No Xcode project, no SwiftPM, no third-party dependencies — `build.sh` is essentially one `swiftc` call.

```bash
git clone https://github.com/Zephyr-777/RestReminder.git
cd RestReminder
./install.sh
```

`install.sh` compiles, installs to `~/Applications`, installs the Python reporting tools, ad-hoc signs, registers and launches.

If Gatekeeper blocks the first launch (the app is not notarized), allow it under System Settings → Privacy & Security, or run:

```bash
xattr -dr com.apple.quarantine ~/Applications/RestReminder.app
```

---

## Data & privacy

- **Everything is local.** No network requests, no account, no telemetry, no crash reporting.
- Statistics are plain JSON under `~/Library/Application Support/RestReminder/`.
- Reading Apple's Screen Time is **optional**; without Full Disk Access the rest still works.
- **iPhone / iPad screen time is not available** — not because it was skipped, but because it isn't possible: cross-device data lives in a private CloudKit container, never touches this Mac's disk, and Apple exposes no API (`DeviceActivity` / `FamilyControls` are for managing your own app's usage only).

---

## Known limitations

- **Apple Silicon only** as shipped — edit the `-target` in `build.sh` for Intel.
- **Not signed or notarized** — ad-hoc signing only.
- **"Real display sleep" relies on a private path** (`CGDisplayForceToSleep` family); if a future macOS breaks it, use the looping-screen mode instead.

---

## License

[MIT](LICENSE) © 2026 Zephyr
