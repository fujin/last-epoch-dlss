# Last Epoch Graphics

Experimental integration of native-resolution DLAA, NVIDIA frame generation and optional DLSS 5 Neural Rendering into Last Epoch's Windows DirectX 11 renderer.

This is a **source-only prototype**: build/deployment scripts, validation summaries and corresponding backend patches are included. Runtime DLLs, proprietary models, game files and generated game references are excluded.

| Feature | Recorded evidence |
| --- | --- |
| Native-resolution DLAA | Visible output and successful NVIDIA evaluations at 1600×900 and 5120×1440. |
| NVIDIA frame generation | Requested 2×/3×/4× modes produced matching DXGI presentation-call ratios. |
| DLSS 5 Neural Rendering | Actual model evaluation/composition and scene comparisons with NR enabled/disabled. Optional; initially disabled. |
| Scene capture before UI | Upright, matching scene color and listed UI omissions verified in Old Road at 5120×1440, with NR off/on. |

**Reduced-resolution DLSS Super Resolution is unsupported.** Quality, Balanced and Performance produced incorrect output and are guarded in the normal build. The 240 FPS goal was not reached. DXGI call counts do not independently establish unique generated images or physical display cadence; frame generation does not multiply game simulation or input responsiveness.

Testing used offline play, an RTX 5080, Last Epoch 1.5.3 / Steam build 26087601, Unity 6000.4.8f1 and BepInEx 6.0.0-be.791. A corrected backend passed a bounded 23-minute menu/control test and a final smoke test. Broader scene/stability coverage, online compatibility and other hardware remain unverified. See the [runtime audit](docs/dll-compatibility-audit.txt), [7 November compatibility test](docs/validation/runtime-20261107.txt) and [exact artifact identities](packaging/source-candidates.json).

The managed BepInEx plugin hooks Unity PPv2's temporal resolve and supplies scene color, depth, motion and jitter to a native D3D11 bridge. The modified OptiScaler backend connects those resources to NVIDIA features through D3D11/D3D12 interop. A separate postprocessed scene capture runs before later UI rendering. Lossless Scaling is not required.

For development, start with the [fresh-clone prerequisites](REPOSITORY.txt), [pinned dependencies](packaging/build-prerequisites.json) and [backend reconstruction instructions](packaging/patches/README.txt). Full builds require Windows/MSVC x64, CMake, the pinned .NET SDK/loader, Streamline headers and locally generated game interop. The [detailed manual](README.txt) covers generation, build, installation and recovery; cloning alone does not prepare an installation.

Use the [read-only preflight](docs/preflight.txt) to inspect source prerequisites and a staged candidate before installation. It reports file conflicts and unverified requirements without changing the game.

Once reviewed binaries and dependencies are staged, the tested NR-off profile is:

```powershell
.\scripts\Set-Profile.ps1 -Profile DLAA -Multiplier 4 -NeuralRenderingScale 0.5 -LateHudless -Install
```

Close the game before installation, profile deployment or removal. Keep the deployment journal and original backups. Preview removal with `scripts/Restore.ps1 -WhatIf`, then run `scripts/Restore.ps1`. The offline launcher may still show Login / Play Offline: select Play Offline explicitly.

Insert opens the backend menu by default; its key can be rebound. Without Insert, close the game, set `ShortcutKey=0x7a` under `[Menu]` in the game folder's `OptiScaler.ini`, save and restart to use F11. F10 toggles the developer panel; its clicks can also reach gameplay. F8/F9 remain game keys.

Follow the [issue tracker](https://github.com/fujin/last-epoch-dlss/issues) and [release plan](docs/public-release-plan.txt). Offline CI checks native WARP contracts, deployment fixtures and read-only preflight; it cannot validate NVIDIA rendering or game visuals.

Original project files use [MIT](LICENSE). The native bridge and adapted managed wire bindings retain Apache-2.0; OptiScaler patches retain GPL-3.0; third-party runtime/model terms remain separate. See [NOTICE](NOTICE).
