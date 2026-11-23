# Install on Linux with Steam and Proton

This release was play-tested on Linux/Proton with Halo Steam build `24670874`.

**Shots of Master Chief require the Perspective (third-person) skull.** Enable **Perspective** on the **Select Skulls** screen before starting the mission, then press **F8** during gameplay. Entering photo mode from first person can show duplicate arms and weapons on Chief.

1. Launch Halo once to create its Proton profile, then close the game. Extract the complete Linux release ZIP.
2. For the F9 shutter, use an X11 or XWayland game window. Install Python 3, Pillow, ImageMagick (the `import` command), `xdotool` and `xprop` in the environment Steam uses to start the game. On Debian or Ubuntu the packages are `python3 python3-pil imagemagick xdotool x11-utils`.
3. For a fresh UE4SS installation, download **UE4SS_v4.0.0.zip** and **zCustomGameConfigs.zip** from the official v4.0.0 release. Save both unopened ZIPs in your Downloads directory. The installer verifies both SHA-256 digests and installs the Halo Steam profile used in testing. If you already use a working UE4SS v4 Halo Steam setup in the game's `Win64/ue4ss` directory, skip these downloads. [Official UE4SS v4.0.0 downloads](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0)
4. Open a terminal in the extracted release folder and run the command below. It locates Halo in Steam's libraries. If needed, add `--game "/path/to/Halo Campaign Evolved"` using Steam's **Manage → Browse local files** location.

   ```sh
   python3 -B packaging/linux/install.py --archives "$HOME/Downloads"
   ```

5. Copy the launch option printed by the installer into Halo's **Properties → General → Launch Options**. It starts the installed capture helper and Halo together. If you already have options, preserve your other environment variables, DLL overrides and game flags, with one `%command%`. The helper is installed in the game folder, so you can move the extracted release after installation.
6. Launch Halo, load a solo mission, and press **F8** while you control the player. Move the camera, press **F9** for a PNG, then **F8** to resume. Photos are saved inside the game library at `steamapps/compatdata/2806050/pfx/drive_c/users/steamuser/AppData/Local/Meteorite/Saved/Screenshots/Windows`. Search the game's `Meteorite/Binaries/Win64/ue4ss/UE4SS.log` for `[HaloPhotoMode]` for capture results and the exact PNG path.

## Existing loaders and upgrades

The installer copies the camera into `ue4ss/Mods/HaloPhotoMode` and puts the Linux helper inside its `Proton` folder. When upgrading an existing camera, it saves the previous folder under `Win64/HaloPhotoMode-backup-*`. An existing loader keeps its active profile and other mods. If the loader stalls before starting Lua, the tested v4.0.0 configuration uses the upstream Halo Steam profile with `bForceGUObjectArrayForIteration = true` and the optional `UE4SS_Signatures/GUObjectHashTables.lua` disabled.

For a custom or legacy loader location, copy `mod/HaloPhotoMode` from the release into its active `Mods` directory. Copy `tools/capture.py` and `tools/doctor.py` together into a new `Proton` folder inside the installed mod. Keep the existing loader launch environment and insert `python3 -B "/absolute/path/to/HaloPhotoMode/Proton/capture.py" --run` immediately before `%command%`. A fresh standard setup uses `WINEDLLOVERRIDES="dwmapi=n,b"`. If your mod list explicitly disables HaloPhotoMode, enable its entry.

## Uninstall

Close Halo, restore the previous Steam launch options, and move `HaloPhotoMode` out of the loader's `Mods` folder. Remove the `HaloPhotoMode : 1` line from `Mods/mods.txt` if present. To restore a previous camera version, copy it from the backup folder into `Mods` and restore its corresponding launch options. For a fresh loader installed solely for this camera, move both `dwmapi.dll` and the entire `ue4ss` directory out of `Meteorite/Binaries/Win64`. Keep these shared loader files when other mods use them. Captured PNGs are stored separately in the Proton prefix.
