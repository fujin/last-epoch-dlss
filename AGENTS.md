# Working on Last Epoch DLSS

## Goal and priorities

The user wants responsive play at 5120x1440 on an RTX 5080, targeting sustained
240 Hz with Neural Rendering, followed by a usable public release.

1. Get reduced-resolution SR working correctly (#1). Start with 90% linear
   scale: 4608x1296 input reconstructed to 5120x1440, with native HUD and correct
   mouse targeting. Prove the image/resource dimensions before benchmarking.
2. Improve real rendering performance and input response with NR on (#4, #2),
   using the normal Reflex path. Measure bottlenecks before optimizing them.
3. Resolve output/input/stability release blockers (#3, #5, #6), then complete
   installation, dependency distribution and recovery requirements.

Do not follow an incidental bug into a separate project. The fallback limiter
is normally bypassed by Reflex here; dedicated fallback diagnostics are deferred.
A higher generated-FPS counter alone does not satisfy the performance goal.

## Work and tracking

- Use the existing GitHub issues as the source of task status and acceptance
  checks: https://github.com/fujin/last-epoch-dlss/issues. A Project board is
  deferred; do not spend time setting it up without renewed user direction.
- Make small implementation changes that advance an acceptance check. Prefer a
  runnable, isolated candidate over another plan, audit or report.
- After testing, update the affected issues with the exact build/settings,
  result, limits and next step. Keep partial checks open and link the commit.
- Keep documentation lean: edit the README or existing relevant document.
  Do not add a standalone text report for every session or duplicate the backlog.
  Keep raw logs, captures, backups and generated build manifests in ignored paths.
- Distinguish implementation, compilation, resource-contract tests and actual
  game validation. Report no performance or latency improvement unless measured.

## Build and runtime boundaries

- Inspect the current checkout and relevant source before relying on old notes.
  Preserve unrelated changes and the user's playing installation/settings.
- Build experimental SR separately; keep its normal-build guard until visual,
  resource, HUD/input and scene-transition checks pass. Do not promote a candidate
  merely because it compiles or passes software/WARP tests.
- For game-free work, use an isolated build. scripts/Build.ps1 also stages outputs;
  do not use it as a harmless compile check. Keep selected artifact pins intact.
- Launch/control the game only during an authorized runtime session and respect
  its time limit. Back up before swapping files, restore the playing configuration
  afterwards, and verify restoration. Earlier testing permission is not perpetual.
- Keep source and runtime distribution distinct. Follow NOTICE and the existing
  release plan; do not publish game files, interop assemblies, models, private
  logs or unreviewed dependencies. No binary release without its required checks.
