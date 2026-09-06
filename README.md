# Webparatus DLSS5 Sidecar V3

Build workspace for the Webparatus edition of the external DLSS 5 sidecar for World of Warcraft.

**Developer (Webparatus edition): Klede Marcos Teixeira**  
**Channel:** Webparatus — YouTube

This edition is based on xilla420/dlss5-wow-sidecar v0.1.2 and preserves the original MIT license and third-party notices. It remains an external sidecar: no DLL is installed into the World of Warcraft folder, no code is injected into WowClassic.exe, and no game memory is read.

Targets:
- Windows 10 22H2 build 19045 and Windows 11
- NVIDIA RTX 20 / 30 / 40 / 50 (RTX 20/30 experimental)
- World of Warcraft Classic / Mists of Pandaria Classic in borderless windowed mode

The GitHub Actions workflow builds the patched executables and packages them with the upstream v0.1.2 runtime bundle.
