# Halo: Campaign Evolved photo mode

The first playable milestone is a single F8 → F9 → F8 session. Freeze a moving subject in a solo mission, move the camera away, save a clean photograph, then resume from the same moment. The full target adds photographic exposure, focus, film treatment, HDR development and high-resolution print capture. The README records which steps have live evidence on Halo. The Denshattack handoff supplies control conventions and comparison cases. [Project status and controls](README.md) · [Denshattack! Photo Camera](https://github.com/NewBarkTownKris/denshattack-photo-camera)

## Steam build and runtime

| Evidence | Recorded value |
| --- | --- |
| Steam installation | App `2806050`, build `24670874`, Win64 under Linux/Proton |
| Game build | `2026.08.11.1121610.2-Rel-i343-Meteorite-2607-CU4` |
| Retail executable | `Meteorite/Binaries/Win64/HaloCampaignEvolved.exe`, SHA-256 `eb1daca659207f2b5c8a6fd922917195ae9c8ae19e771e396e08906282a4b152` |
| Upstream UE4SS v4.0.0 | `UE4SS_v4.0.0.zip`, verified SHA-256 `251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45` |
| Matching configuration archive | `zCustomGameConfigs.zip`, verified SHA-256 `1fd90a875138534cc11a7aee802bfb4b4f08e8614ff1709796fb363e2dab9c2d` |

The test installation uses the upstream Halo Steam profile with its optional object-hash lookup disabled and `HaloPhotoMode` as its sole installed mod. The profile specifies UE 5.5 and the engine-tick scheduler. Existing Halo mod documentation gives `WINEDLLOVERRIDES="dwmapi=n,b" %command%` for Proton. Recheck the build and executable with `python3 tools/doctor.py --sha256 --settings` after a Steam update. [Release asset digests](https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/v4.0.0) · [Tagged Steam profile](https://github.com/UE4SS-RE/RE-UE4SS/tree/v4.0.0/assets/CustomGameConfigs/Halo%20Campaign%20Evolved/steam) · [Halo mod author's Proton notes](https://www.nexusmods.com/halocampaignevolved/mods/279?tab=description)

The retail executable's Unreal Header Tool records identify the following title-specific interfaces. Their presence establishes the call signatures. A moving subject and a restored gameplay view are the live tests of their behavior.

| Owner | Reflected call |
| --- | --- |
| `/Script/Meteorite.MeteoritePlayerController` | Instance `SetGameAndBlamPaused(WorldContextObject, bPause)` returns void |
| `/Script/Meteorite.MeteoriteUIStatics` | Static `IsInGameplayState(WorldContextObject)` returns bool |
| `/Script/BlamEngine.BlamEngineAudioGameSubsystem` | `IsNetworkCoop()` and `GetIsPaused()` each return bool |
| `/Script/BlamEngine.BlamCinematicSubsystem` | `IsCinematicInProgress()` returns bool |

## Implementation and acceptance

1. **Freeze, detach, photograph, resume.** Start at a repeatable solo checkpoint with a moving character in view. Record the mission, checkpoint, viewport and build. Sample the player camera manager's evaluated pose and FOV, request the campaign pause through the Halo controller, check the Blam acknowledgment, and update the detached camera against real time while Unreal renders. Compare before, frozen and resumed frames. Check that the subject holds its pose, independent camera translation reveals parallax, the saved PNG contains neither HUD nor finder, and gameplay input returns without firing or opening a menu. Repeat with an already-hidden HUD, pre-paused game, failed entry, checkpoint reload and world change. Verify rejection in menus, cinematics and co-op. The first implementation is in [the session adapter](mod/HaloPhotoMode/Scripts/session.lua) and [PNG shutter](mod/HaloPhotoMode/Scripts/shutter.lua).

2. **Lens, framing and controls.** Verify six-axis travel, roll reset, fine/fast movement and long-lens aim on keyboard, mouse and a physical controller. Compare 16, 24, 35, 50, 85, 135, 200 and 600 mm full-frame-equivalent presets against measured horizontal FOV. Use one centered integer crop for finder and file. Check viewport, 3:2, 4:3, 1:1, 16:9, 5:4, 21:9, 65:24 and the 89:35 print spread in both orientations. At 3840 × 2160 the 65:24 crop should be 3835 × 1416. Inspect the thirds, reticles, guide and cropped edges against in-scene landmarks. Resize during capture and verify a clean retry.

3. **Focus and depth of field.** Verify collision and distance units using near, middle and far subjects. A single center trace locks the first visible surface. Continuous autofocus follows a changing target and retains the previous plane on a miss. Compare manual 20% and 1% steps, f/1 through f/16 and 1×/2×/4×/8× DOF strength on one frozen composition. Verify finder feedback against the sharp region and check that normal gameplay focus returns.

4. **Linear HDR, metering and Studio.** Pair the display PNG with an opaque three-channel, pre-display-transform EXR at the same pose, projection and crop. Determine Halo's working primaries, white point and pre-exposure before producing a scene-linear Rec.709/D65 master. Check channel order, highlights above 1.0, metadata and matching landmarks. Keep Game exposure as the default. Calibrate 18% gray, then test Manual, Aperture Priority and Shutter Priority across dark and bright scenes, Auto ISO limits, minimum shutter and ±5 EV compensation. Cover 8 s–1/32000 s and ISO 100–6400. At fixed aperture and shutter, ISO 200 should yield twice the signal at ISO 100. Each priority result must use a meter reading for the current pose and crop.

5. **Film, settings and delivery.** Add Studio navigation for keyboard and controller, the ±3 EV meter, eleven film presets, ISO-dependent grain and independent chromatic aberration control. Defaults are Neutral film, grain Off and game chromatic aberration. Verify grade and grain on the display PNG while the EXR retains its documented scene-linear exposure. Persist camera preferences in a Halo-specific namespace and reset focus per session. Exercise the destination picker on Windows and Proton, including changes between shots, canceled selection and unavailable media.

6. **Timed and print shutters.** For photographic shutters of 1/15 s or slower, lock focus, lens and exposure, then record camera motion against elapsed real time while the simulation stays frozen. Accumulate up to 64 poses on separate display and linear paths. Compare 1/15 s and 1/2 s on the same pan. Verify cancellation, timeout, staging cleanup and a completed PNG surviving an EXR failure. Add 1×–4× raster scaling while preserving finder FOV and metering area. Derive texture and memory limits on Halo. At 4×, the example 65:24 crop should be 15340 × 5664. Compare resolved detail, seams, shadows, memory and duration against 1×, including portrait and 89:35. Evaluate pixel-shift or overlapping bands only where single-pass rendering exceeds measured limits.

7. **Offline development and release.** Develop verified EXRs to ARRI Wide Gamut 3 / LogC3 EI 800 TIFF, Fujifilm F-Gamut / original F-Log TIFF and linear RGB DNG. Check 16-bit TIFF codes, recorded highlight-protection offsets, DNG profile and exposure metadata against a reference chart. Open real outputs in grading and raw-development software. Test Windows and Linux/Proton archives, checksums, fresh install, upgrade, repair and uninstall with an existing loader and other mods. Ship mod code, license notices and helpers as a noncommercial community mod in line with the title's published guidelines. [Halo Studios modding guidelines](https://www.halowaypoint.com/news/early-access-primer)

For each milestone, record the automated checks, game build, platform, scene and observed result in the README. Preserve representative images or paired pixel measurements for photographic claims. Record an untested platform or unsupported capture path alongside the feature it affects.
