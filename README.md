# Halo: Campaign Evolved Photo Mode

Freeze a solo campaign mission, move the camera away from Chief and take a cropped PNG. The camera includes roll, focal-length presets, manual and automatic focus, adjustable depth of field, and portrait and panoramic framing. It uses the game's exposure.

**Gameplay has only been tested on Linux through Proton. Native Windows gameplay is untested.** Master Chief can appear with two sets of arms and two weapons when viewed from the detached camera.

## Download and install

| Platform | Download | Installation |
| --- | --- | --- |
| Linux / Proton | [Linux ZIP](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/releases/download/v0.1.0/HaloPhotoMode-0.1.0-linux-proton.zip) | Extract the ZIP and follow [the Linux setup guide](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/blob/main/packaging/linux/INSTALL-Linux.md). It prints the Steam launch option for your installation. |
| Windows x64 | [Windows ZIP](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/releases/download/v0.1.0/HaloPhotoMode-0.1.0-windows.zip) | Extract the ZIP, run `Install-Windows.cmd`, then start the capture helper before launching Halo. See [the Windows setup guide](https://github.com/NewBarkTownKris/halo-campaign-evolved-photo-camera/blob/main/packaging/windows/WINDOWS.md) for prerequisites. |

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
| F9 | Save one cropped PNG in Unreal's screenshot directory |
| F8 | Enter or resume |
| Analog sticks, shoulder buttons | Move and aim, change height |

The finder and PNG use the same centered crop in viewport pixels. Focal lengths assume a 36 mm horizontal gate. This build uses the game's exposure. Shutter results, exact save paths and entry failures are reported with the `[HaloPhotoMode]` prefix in `ue4ss/UE4SS.log`.

### Proton shutter

The tested F9 path captures the XWayland client pixels after the finder disappears. It requires Python 3, Pillow, ImageMagick's `import`, `xdotool` and `xprop`. It produces an 8-bit display PNG. Halo's native `HighResShot` request timed out twice on this build, including with its screenshot directory already present.

The Linux installer prints a Steam launch option that starts the helper alongside Halo. PNGs are saved under the app's Proton prefix in `drive_c/users/steamuser/AppData/Local/Meteorite/Saved/Screenshots/Windows`. On Windows, the helper watches `%LOCALAPPDATA%\Meteorite\Saved\Screenshots\Windows`.

## Development

Run `python3 tools/doctor.py --sha256 --settings` to identify the Steam installation, game build, loader directory and saved FOV/HUD preferences. The [implementation plan](IMPLEMENTATION_PLAN.md) records the tested configuration and the remaining work on exposure, film emulation, EXR and print output. Build both distributions and the SHA-256 manifest with `python3 tools/build_release.py`.

## Live results

On November 23, 2026 the installed mod ran in *Assault on the Control Room* on Steam build `24670874` under Proton at 3840 × 2160.

- F8 rejected the main menu and entered from the solo checkpoint. During a jump Chief stayed airborne for 27.64 seconds while the detached camera moved and took a photo. His reported height covered a 14.22 cm range during that interval. After F8 he landed within 0.04 cm of his pre-jump height. The rifle, HUD and first-person view returned. Blam acknowledges the pause while Unreal continues rendering, so some particles and screen effects can still animate.
- The finder masks matched a decoded 3835 × 1416 panoramic PNG and a 792 × 2145 portrait PNG. F8 during a shot waited for the output before resuming. The photos exclude the finder, grid, and gameplay HUD. Steam's configured launcher started the helper and saved additional 3840 × 2160 photos on a fresh launch.
- At the same 135 mm camera pose and f/2.8 equivalent aperture, center autofocus reported 103.29 m. Moving manual focus to 5.59 m visibly softened the distant wreck. Both full-resolution PNGs were opened and compared.
- The near-eye camera hides the local first-person body and weapons while the lens is inside the entry radius. Moving away restores the models for composition. After filtering the hidden equipment out of autofocus, a final eye-position shot locked at 97.96 m and saved before resuming. Other missions, physical gamepads, and native Windows gameplay still need coverage.

### Why Chief can have duplicate arms

On *The Silent Cartographer*, entering photo mode on foot left Halo's player pawn in first-person mode. Once the camera moved 55 cm from the entry point, the mod restored the pawn and both weapon actors. The detached camera could then see Chief's first-person arms and his full character at the same time.

In a fixed-pose Linux test with classic Mk V armor, hiding the pawn's two first-person arm components (armor and shield) removed the extra arm pose. Hiding the first-person Magnum actor also made both visible pistol images disappear. Chief's body remained visible. The camera currently retains the game's starting perspective.

## Automated checks

Run these checks from the project root.

```sh
for test in tests/*_test.lua; do lua5.4 "$test" || exit 1; done
python3 -B -m unittest discover -s tests
```

The Lua tests cover capture sequencing, file completion, viewport changes, shared crop and lens math, viewfinder positioning, entry rollback and restoration on travel. The Steam diagnostic has fixture coverage for secondary libraries and stale installations. These checks run without Halo.
