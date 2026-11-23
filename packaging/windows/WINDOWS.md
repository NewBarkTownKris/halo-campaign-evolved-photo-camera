# Halo Photo Mode for Windows

Gameplay has only been tested on Linux through Proton. Native Windows camera controls and F9 capture are unverified. Chief can show duplicate arm models when the detached camera faces him.

## Install

1. Close Halo. Extract the **Windows** release ZIP to a folder you can keep, such as `Documents\Halo Photo Mode`.
2. Install Python 3.10 or later with the Windows `py` launcher. From Command Prompt, run `py -3 -m pip install "Pillow>=11.2.1"` for the F9 capture helper. The helper uses Pillow's single-window capture support. [Python for Windows](https://www.python.org/downloads/windows/) · [Pillow ImageGrab](https://pillow.readthedocs.io/en/stable/reference/ImageGrab.html)
3. For a fresh loader installation, download both `UE4SS_v4.0.0.zip` and `zCustomGameConfigs.zip`. Place both ZIPs beside `Install-Windows.cmd`, keeping them zipped. The installer verifies the pinned downloads and applies the Halo Steam profile. With an existing compatible UE4SS v4 installation configured for Halo, skip the downloads. [Official UE4SS v4.0.0 assets](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0)
4. Run `Install-Windows.cmd`. The installer searches Steam libraries for app 2806050. To choose the game manually, open a Command Prompt in the extracted folder and run the command below, substituting the path opened by Steam's **Manage → Browse local files**.

```bat
Install-Windows.cmd --game "D:\SteamLibrary\steamapps\common\Halo Campaign Evolved"
```

## Take a photo

Run `Start-Windows-Capture.cmd` from the extracted folder before your session and keep the console open. Start Halo normally from Steam, load a solo checkpoint, and use a visible, focused window in windowed or borderless mode. Press **F8** to freeze and detach, **F9** to save the selected crop, then **F8** to resume. The helper captures the game window in 8-bit display color. Close the helper after playing. See `README.md` in the release for lens, movement, focus and finder controls.

Paste `%LOCALAPPDATA%\Meteorite\Saved\Screenshots\Windows` into File Explorer to open your photos. If a shot fails, check the helper console and the `[HaloPhotoMode]` messages in `ue4ss\UE4SS.log` beside the gameplay executable. If a different file path is logged, run `py -3 -B capture_windows.py --directory "D:\path\from\the\log"` from the extracted folder. For a black image, try windowed mode and keep the game completely visible during capture.

## Upgrade or remove

Close Halo and the helper. Running the installer again with a newer release backs up a replaced camera under `Win64\HaloPhotoMode-backup-*\HaloPhotoMode`. To remove the camera, move `ue4ss\Mods\HaloPhotoMode` outside `Mods` and remove its `HaloPhotoMode : 1` entry from `Mods\mods.txt` if present. You can then remove the extracted release folder. For a fresh loader installed exclusively for this camera, remove its `dwmapi.dll` and `ue4ss` directory beside `HaloCampaignEvolved.exe`. Keep both if your other mods use that loader.
