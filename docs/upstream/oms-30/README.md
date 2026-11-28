# OMS-30 upstream drafts

Drafts of the reports and pull requests from the J616c's macOS 27.2 bring-up (JOURNEY 9.57 to
9.63). Each file names where it goes and needs Allan's go-ahead. aurora-silicon forbids AI
attribution (its pre-PR checklist), so nothing sent there mentions it.

Sent: 01 as aurora-silicon/linux#3496 (draft) and 05 as omacom/omarchy-pkgs#3854 (2026-11-28). The rest went to Allan's J616c thread on
the M team's Basecamp as one report, for the team to pick up.

| Draft | Goes to | Kind |
| --- | --- | --- |
| [01-linux-gpu-32core-26b123.md](01-linux-gpu-32core-26b123.md) | aurora-silicon/linux | PR, with `patches/linux-t6041-26b123-32core.aurora-main.patch` |
| [02-linux-ane-ave-27.2.md](02-linux-ane-ave-27.2.md) | aurora-silicon/linux | issue |
| [03-linux-t6041-fw27-alpha-only-plane.md](03-linux-t6041-fw27-alpha-only-plane.md) | aurora-silicon/linux | issue |
| [04-omarchy-kmscon-appledrmfb.md](04-omarchy-kmscon-appledrmfb.md) | omacom/omarchy | comment on #20512 |
| [05-omarchy-pkgs-hyprland-alpha-variant.md](05-omarchy-pkgs-hyprland-alpha-variant.md) | omacom/omarchy-pkgs | PR, with `patches/hyprland-alpha-variant-buffer-present.patch` |

The machine throughout: MacBook Pro 16-inch, M4 Max (Mac16,5, J616c, T6041), 14-core CPU,
32-core GPU, system firmware and stub macOS 27.2 (26B123, iBoot mBoot-20457.41.3), Omarchy edge
(`linux-aurora 7.3.0.aurora1-1` from omacom/linux-aurora `3058cc5c`), aura `v1.0.0b17` Stage 1
(padded Mach-O) and Stage 2.
