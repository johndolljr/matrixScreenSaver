# macOS Matrix Screen Saver

![macOS Matrix Screen Saver demo](docs/matrix-screensaver.gif)

This is a macOS screen saver based on the iconic rain of characters and symbols known from the movie The Matrix.

## Quick install

```bash
brew trust --cask patrickschaper/tap/matrix-screen-saver
brew install --cask patrickschaper/tap/matrix-screen-saver
```

## Buy me a coffee

There is no spoon. There is coffee. Donations help fund a developer license for signing the screen saver.

<a href="https://www.buymeacoffee.com/yesman82"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" width="150"></a><br>
<img src="docs/bmc_qr.png" alt="Buy Me a Coffee QR code" width="150">

## Options

The saver exposes a native **Options…** sheet. The values are stored with `ScreenSaverDefaults`.

| Option | Description | Default |
| --- | --- | --- |
| Number scene | Show the startup number scene before continuous rain. | On |
| Twinkle | Turn on/off the twinkling effect. | On |
| Diffuse | Turn on/off the glow effect. | On |
| Character size | Set the character cell width and height in pixels.<br>Example pairs: 8 x 15, 9 x 17, 10 x 19, 11 x 21, 12 x 23, and 13 x 24. | 9 x 17 |
| Rain density | Set the factor for the density of rain drops. A positive number. | 1.0 |
| Frame rate | Set the frame rate per second. A positive number less than or equal to 1000. | 25 |
| Error rate | Set the factor for the rate of character changes. A non-negative number. | 1.0 |
| Characters | Restrict rain glyphs to a custom set (e.g. ATGC). Leave empty for the default. | *(empty)* |
| Neo message scene | Show the Neo message intro before the main scene. | On |
| Neo message speed | Typing and pause speed multiplier for the Neo message intro. A positive number. | 1.0 |
| Neo message lines | Lines typed during the Neo message intro. Between 1 and 10 lines, up to 256 characters each. | The 4 classic lines |
| Scan lines intensity | Opacity of the CRT scan line overlay (0 = off, 100 = fully opaque). | 25 |
| Scan lines vertical | Orientation of the scan line overlay (vertical or horizontal). | On (vertical) |

## Development

### Desktop wallpaper app

Build and launch the separate native menu bar app:

```bash
./build-wallpaper.sh
open build/MatrixWallpaper.app
```

To install a stable copy in your user Applications folder:

```bash
./install-wallpaper.sh
open ~/Applications/MatrixWallpaper.app
```

The installer gracefully quits running Matrix Wallpaper copies before building or
updating, and cancels if they do not quit within five seconds. It builds and
verifies the app before replacing an existing installation; preferences
are kept outside the bundle. It does not launch the app or enable login startup.
You can also double-click the installed app in Finder. It appears in the menu bar,
not the Dock.

The **Matrix** menu provides **Start / Stop**, **Options…**, one **Launch at Login**
checkbox, and **Quit**. On macOS 13+, Launch at Login uses the
system's registration, and refreshes whenever the menu opens so changes made in
System Settings are reflected. Checking registers and enables startup; unchecking
stops future login launches. Apple's API does this by unregistering, so keeping a
disabled entry visible in System Settings is not guaranteed. An unchecked item
marked **Approval Required** means macOS has not granted approval (or approval was
revoked). Settings opens automatically when approval is needed; clicking the
unapproved item opens Settings again without removing its registration. Errors are
reported without claiming startup is enabled. Disabling startup does not stop the
current wallpaper, and Quit does not disable startup. Older macOS versions support
manual launching only. Use the installed copy when enabling startup; login and
approval behavior still need verification on your macOS version with these
locally ad-hoc-signed builds.

It renders the real saver independently on each display, with distinct rain and
coordinated scenes. Passive desktop-level windows leave input to Finder and do
not change your macOS wallpaper settings. Stop or Quit reveals your existing wallpaper.

Options use the same `dev.patsch.MatrixScreenSaver` preferences as the screen saver.
Changes made in the app apply to all wallpaper displays and future saver sessions.
Glow, twinkle, rain density, glyphs, frame rate, error rate, and scan lines update
in place without replaying the intro. Character size, intro settings, and rain
cycle mode/duration restart all displays together.
Changes made elsewhere are reloaded on Start and when opening Options; running
processes do not continuously synchronize preferences.

Playback suspends for sleep, inactive sessions, lock, and screen saver activity.
Stop remains stopped after wake or unlock. Temporary suspension preserves the
current rain and intro state and excludes paused time from scene clocks.
Actual display geometry/scaling changes rebuild the coordinated session;
unchanged display notifications on wake do not restart it.
Lock and saver detection supplements public workspace notifications with
best-effort macOS distributed signals; delivery is not guaranteed.

No System Settings wallpaper registration or private Wallpaper.framework
integration is installed. The existing `.saver` build and
installation remain separate. Desktop behavior across widgets, Spaces, Show Desktop,
Stage Manager, and fullscreen apps should be checked on the macOS version you use.

Run the additional AppKit checks from a logged-in graphical macOS session:

```bash
./wallpaper-tests.sh
./wallpaper-install-tests.sh # requires a built wallpaper app; uses a temporary HOME
```

These check native animation, passive windows, shared options UI, menu actions,
notification-driven suspension, display reconciliation, and cleanup. They briefly
create desktop windows and open Options; they do not alter your saved saver settings.
Login-item tests substitute system operations and do not change your real login
items. Installer checks exercise copying, verification, replacement, and rollback
without touching your Applications folder. Actual login startup (one instance
after logout/login, then none after disabling), System Settings approval and
synchronization, lock/sleep/saver transitions, and physical display hotplug still
need live checks.

### Current state

- Native Swift/AppKit screen saver bundle
- Edge-to-edge full-screen saver output, with terminal-style chrome kept in the preview host
- In-process renderer for `rain-forever` with an optional upstream `number` intro
- Native **Options…** sheet for Number scene, Twinkle, Diffuse, Character size, Rain density, Frame rate, Error rate, Characters, Neo message scene/speed/lines, and Scan lines
- Preview app for fast iteration without reinstalling

### Repository layout

- `Sources/MatrixScreenSaver/MatrixScreenSaverView.swift` - screen saver view, layout, drawing, and option wiring
- `Sources/MatrixScreenSaver/NativeMatrixRenderer.swift` - native Matrix scene renderer
- `Sources/MatrixScreenSaver/MatrixScreenSaverOptions.swift` - options model and native configure sheet
- `Sources/MatrixScreenSaver/TerminalSupport.swift` - small shared terminal types used by the active renderer
- `Scripts/install-saver.sh` - shared ditto-based installer used by local installs
- `Tools/PreviewHost.swift` - local preview host used by `./preview.sh`
- `Resources/Info.plist` - bundle metadata

### Requirements

- macOS
- Xcode Command Line Tools with `swiftc`

Full Xcode is not required.

### Build

```bash
./build.sh
```

This creates the screen saver bundle:

```text
build/MatrixScreenSaver.saver
```

`build.sh` reads the current version from `./VERSION` and writes it into the saver bundle metadata.

### Test

```bash
./tests.sh
```

Compiles and runs the test suite using `swiftc`. No Xcode required — Command Line Tools are sufficient.

### Preview without installing

```bash
./preview.sh
```

This rebuilds the bundle, compiles the preview host, and opens the saver in a normal macOS window for quick iteration.

### Install

```bash
./install.sh
```

`install.sh`:

1. rebuilds the saver bundle
2. strips quarantine from the source bundle and copies it to `~/Library/Screen Savers/MatrixScreenSaver.saver`
3. verifies the installed executable matches the build output
4. stops running `ScreenSaverEngine` / `legacyScreenSaver` processes so macOS reloads the updated bundle

After installing:

1. open **System Settings > Wallpaper > Screen saver...**
2. select **MatrixScreenSaver**

To relaunch the screen saver host manually:

```bash
open -a ScreenSaverEngine
```

### Origin

This project started as an attempt to wrap `cxxmatrix` inside a macOS screen saver.

The current implementation is based on the upstream [`akinomyoga/cxxmatrix`](https://github.com/akinomyoga/cxxmatrix) project and keeps its look and scene behavior, but it no longer launches an external terminal process at runtime. The active saver is a native in-process Swift/AppKit renderer because `ScreenSaverEngine` did not reliably render the external terminal stream.

The active renderer currently ports `rain-forever` and can optionally start with the upstream `number` intro.
