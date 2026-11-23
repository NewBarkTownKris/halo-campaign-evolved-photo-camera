# Halo: Campaign Evolved Photo Mode

Freeze a solo campaign mission, move the camera away from Chief and take a cropped PNG. The camera includes roll, focal-length presets, manual and automatic focus, adjustable depth of field, and portrait and panoramic framing. The Studio development build adds an in-game settings panel, a chromatic aberration toggle, and a scene-linear EXR for developing log TIFFs. It uses the game's exposure.

**Shots of Master Chief require the Perspective (third-person) skull.** Enable **Perspective** on the **Select Skulls** screen before starting the mission, then press **F8** during gameplay. Entering photo mode from first person can show duplicate arms and weapons on Chief.

Gameplay has only been tested on Linux through Proton. Native Windows gameplay is untested.

## Download and install

Download the **v0.2.0-dev.1 Studio prerelease** for the controls below. The [v0.1.0 stable release](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/releases/tag/v0.1.0) contains the original PNG camera. From a source checkout, `python3 tools/build_release.py` creates both Studio packages under `dist/`.

| Platform | Download | Installation |
| --- | --- | --- |
| Linux / Proton | [Linux ZIP](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/releases/download/v0.2.0-dev.1/HaloPhotoMode-0.2.0-dev.1-linux-proton.zip) | Extract the ZIP and follow [the Linux setup guide](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/blob/v0.2.0-dev.1/packaging/linux/INSTALL-Linux.md). It prints the Steam launch option for your installation. |
| Windows x64 | [Windows ZIP](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/releases/download/v0.2.0-dev.1/HaloPhotoMode-0.2.0-dev.1-windows.zip) | Extract the ZIP, run `Install-Windows.cmd`, then start the capture helper before launching Halo. See [the Windows setup guide](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/blob/v0.2.0-dev.1/packaging/windows/WINDOWS.md) for prerequisites. |

Both packages target the Steam edition (app `2806050`). For a fresh UE4SS installation, download `UE4SS_v4.0.0.zip` and `zCustomGameConfigs.zip` from the official release. Each installer verifies the two downloads and applies the Halo Steam profile. Existing compatible loaders can keep their current configuration. [UE4SS v4.0.0 downloads](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0)

## Using the camera

Load a solo mission, close the pause menu and press F8 while controlling the player. Press F8 again to restore gameplay. If a PNG is in progress, the mod holds the shot until it finishes or times out.

| Control | Action |
| --- | --- |
| WASD, E / Q | Move, rise or descend |
| Mouse or arrow keys | Aim |
| Ctrl / Shift | Move at 0.2× / 4× speed |
| Z / X, F10 | Roll, level the horizon |
| Brackets, F7 | Adjust horizontal FOV, cycle 16–600 mm full-frame equivalents |
| F5 / F6 | Cycle the crop, rotate the selected aspect ratio |
| B, J / K, L | Toggle photographic depth of field, focus nearer or farther, select fine or coarse manual steps |
| N, T | Focus on the center collision surface, toggle continuous autofocus or focus lock |
| U / I, Y | Open or stop down the equivalent aperture, cycle depth-of-field strength |
| H / G | Show or hide the finder, toggle thirds |
| F4 / left-stick click | Open or close Studio. Use arrows or the D-pad to select and change a row |
| F9 / A (Cross) | Save the selected output. Defaults to a cropped PNG |
| F3 / Y (Triangle) | Save a cropped PNG and a scene-linear EXR with the same framing |
| F8 | Enter or resume |
| Analog sticks, shoulder buttons | Move and aim, change height |

The finder and PNG use the same centered crop in viewport pixels. Focal lengths assume a 36 mm horizontal gate. This build uses the game's exposure. Shutter results, exact save paths and entry failures are reported with the `[HaloPhotoMode]` prefix in `ue4ss/UE4SS.log`.

### Studio and log development

Press **F4** while the camera is detached. Up and Down select a row. Left and Right change its value. Set **F9 output** to **PNG + linear EXR** for repeated grading shots, or use **F3** for one pair. **Chromatic aberration** follows the game by default. Select **Off** to suppress color fringing in the detached view. Studio also controls framing, lens, depth of field, focus, thirds and finder visibility. Its preferences are stored under `Meteorite/Saved/HaloPhotoStudio.ini`. Focus distance and tracking mode start fresh each session.

Both shutters hide the finder and Studio. The EXR uses a separate Unreal scene capture at the same pose, lens and crop. It stores floating-point RGB in scene-linear Rec.709/D65 before the display transform. Screen-space effects and particles can differ between the two files. A failed EXR leaves the completed PNG in the screenshot folder.

For log TIFFs, install the optional dependencies from the extracted package. On Linux, run `python3 -m venv .venv` followed by `.venv/bin/python -m pip install -r requirements-develop.txt`. On Windows, run `py -3 -m venv .venv` followed by `.venv\Scripts\python.exe -m pip install -r requirements-develop.txt`.

Run `./Develop-Photos.sh` on Linux or `Develop-Photos.cmd` on Windows to develop the EXRs in Halo's screenshot folder. Pass a single EXR or a folder to select other photos. The developer writes two 16-bit full-range TIFFs beside each master. Use **ARRI Wide Gamut 3 / LogC3 EI 800** for `_logc3.tiff` or **Fujifilm F-Gamut / original F-Log** for `_flog.tiff` in your grading software. Automatic highlight protection records its whole-stop exposure offset in each TIFF. Pass `--ev 0` to keep the EXR exposure. Existing TIFFs are preserved.

### Proton shutter

The tested F9 path captures the XWayland client pixels after the finder disappears. It requires Python 3, Pillow, ImageMagick's `import`, `xdotool` and `xprop`. It produces an 8-bit display PNG. Halo's native `HighResShot` request timed out twice on this build, including with its screenshot directory already present.

The Linux installer prints a Steam launch option that starts the helper alongside Halo. PNGs are saved under the app's Proton prefix in `drive_c/users/steamuser/AppData/Local/Meteorite/Saved/Screenshots/Windows`. On Windows, the helper watches `%LOCALAPPDATA%\Meteorite\Saved\Screenshots\Windows`.

## Development

Run `python3 tools/doctor.py --sha256 --settings` to identify the Steam installation, game build, loader directory and saved FOV/HUD preferences. The [implementation plan](IMPLEMENTATION_PLAN.md) records the tested configuration and the remaining work on exposure metering, film emulation and print output.

## Live results

On November 23, 2026 the installed mod ran in *Assault on the Control Room* on Steam build `24670874` under Proton at 3840 × 2160.

- F8 rejected the main menu and entered from the solo checkpoint. During a jump Chief stayed airborne for 27.64 seconds while the detached camera moved and took a photo. His reported height covered a 14.22 cm range during that interval. After F8 he landed within 0.04 cm of his pre-jump height. The rifle, HUD and first-person view returned. Blam acknowledges the pause while Unreal continues rendering, so some particles and screen effects can still animate.
- The finder masks matched a decoded 3835 × 1416 panoramic PNG and a 792 × 2145 portrait PNG. F8 during a shot waited for the output before resuming. The photos exclude the finder, grid, and gameplay HUD. Steam's configured launcher started the helper and saved additional 3840 × 2160 photos on a fresh launch.
- At the same 135 mm camera pose and f/2.8 equivalent aperture, center autofocus reported 103.29 m. Moving manual focus to 5.59 m visibly softened the distant wreck. Both full-resolution PNGs were opened and compared.
- The near-eye camera hides the local first-person body and weapons while the lens is inside the entry radius. Moving away restores the models for composition. After filtering the hidden equipment out of autofocus, a final eye-position shot locked at 97.96 m and saved before resuming. Other missions, physical gamepads, and native Windows gameplay still need coverage.

### Why Chief can have duplicate arms

On *The Silent Cartographer*, entering photo mode on foot left Halo's player pawn in first-person mode. Once the camera moved 55 cm from the entry point, the mod restored the pawn and both weapon actors. The detached camera could then see Chief's first-person arms and his full character at the same time.

In a fixed-pose Linux test with classic Mk V armor, hiding the pawn's two first-person arm components (armor and shield) removed the extra arm pose. Hiding the first-person Magnum actor also made both visible pistol images disappear. Chief's body remained visible. The camera currently retains the game's starting perspective.

Entering from native third person with the Perspective skull enabled avoided the duplicate arms in a front-facing photo of Chief holding the assault rifle on *Halo*. The original first-person Magnum case remains a known issue.

### Studio capture test

On *Halo*, the Studio build saved a 3240 × 2160 (3:2 landscape) PNG/EXR pair from the 4K viewport while the menu was open. Both files excluded the overlay. The EXR decoded as three half-float RGB channels tagged scene-linear Rec.709/D65, with finite samples throughout. The developer produced full-range 16-bit LogC3 and F-Log TIFFs from that frame. Exposure values are relative to the independent Unreal scene capture.

At a fixed 3840 × 2160 camera pose, changing **Chromatic aberration** from **Game** to **Off** removed a median 7.6 pixels of red–blue separation across 13 high-contrast patches near the image edges. With the effect off, the median landmark displacement between PNG and EXR was 0.14 pixels across 109 samples. Returning to gameplay and re-entering Studio preserved the selected setting.

## Automated checks

Run these checks from the project root.

```sh
for test in tests/*_test.lua; do lua5.4 "$test" || exit 1; done
python3 -B -m unittest discover -s tests
```

The Lua tests cover capture sequencing, file completion, viewport changes, shared crop and lens math, viewfinder positioning, entry rollback and restoration on travel. The Steam diagnostic has fixture coverage for secondary libraries and stale installations. These checks run without Halo.
