# Webparatus DLSS5 Sidecar V3.2 — Fullscreen Capture Edition

Build workspace for the Webparatus edition of the external DLSS 5 sidecar for World of Warcraft.

**Developer (Webparatus edition): Klede Marcos Teixeira**  
**Channel:** Webparatus — YouTube

This edition is based on `xilla420/dlss5-wow-sidecar` v0.1.2 and preserves the original MIT license and third-party notices. It remains an external sidecar: no DLL is installed into the World of Warcraft folder, no code is injected into `WowClassic.exe`, and no game memory is read.

## V3.2 direction

The final play mode is **Windowed Fullscreen / Borderless at native monitor resolution** — visually full screen, with no window frame or title bar.

On Windows 10 22H2 build 19045, V3.2 uses a dedicated fullscreen capture fallback:

- captures the monitor containing WoW instead of the occluded WoW window;
- excludes the Webparatus overlay from capture with `WDA_EXCLUDEFROMCAPTURE`;
- excludes the diagnostic HUD from capture as well;
- keeps the full sidecar pipeline outside the game process;
- keeps RTX 20/30 support experimental, including RTX 3050 Ampere;
- retains the original Windows 11 WGC window-capture path.

This specifically targets the black-frame behavior observed on Windows 10 when a topmost fullscreen overlay completely covers the borderless WoW window.

## Targets

- Windows 10 22H2 build 19045 and Windows 11
- NVIDIA RTX 20 / 30 / 40 / 50 (RTX 20/30 experimental)
- World of Warcraft Classic / Mists of Pandaria Classic
- DirectX 12
- Windowed Fullscreen / Borderless

RTX 20/30 requires a compatible user-supplied `nvngx_dlssnr.dll` via the supplied setup script.

The GitHub Actions workflow compiles x64 Release, verifies the RTX 30 gate is absent, verifies the Windows 10 fullscreen fallback markers, runs upstream unit tests, re-checks forbidden imports, and packages the verified binaries with the upstream runtime bundle.
