# LORT Mod Menu

An in-game mod menu for **LORT**, with gameplay tweaks, fun extras and an achievement unlocker. It's a UE4SS Lua
mod, and the menu is drawn in-game with real UMG widgets in LORT's own font.

**Requires** UE4SS with the LORT layout fix: [lort-ue4ss](https://github.com/9vsv6/lort-ue4ss).

## Install
1. Install UE4SS and the layout fix by following [lort-ue4ss](https://github.com/9vsv6/lort-ue4ss).
2. Copy the `LortModMenu` folder into `...\LORT\bw\Binaries\Win64\ue4ss\Mods\`.
3. Add this line to `ue4ss\Mods\mods.txt`, above the `Keybinds` line:
   ```
   LortModMenu : 1
   ```
4. Launch LORT and press **F1**.

## Keys
| Key | Action |
|---|---|
| F1 / Insert | Open or close the menu |
| Up / Down (Numpad 8 / 2) | Select |
| Left / Right (Numpad 4 / 6) | Change a value |
| Enter (Numpad 5) | Toggle, or run an action |
| Delete | Reset the selected tweak |
| **Noclip:** Space / Left Ctrl | Fly up / down |

## Features
**Player**
- God Mode
- Infinite Dodges: 10 charges, always refilled
- Infinite Heal Potions
- Max Health ×1–20
- Health Regen ×1–50
- Move Speed +0–300%
- Air Jumps

**Combat**
- Damage ×1–50
- One-Hit Kills
- Attack Speed ×1–4
- Crit Chance
- Crit Damage
- Cooldown Reduction 0–100% (100% = no cooldowns for skills and weapon alt-fires)

**Fun**
- Game Speed ×0.1–3
- Player Size
- Gravity
- Jump Height
- Enemy Size
- **Noclip**: fly through walls (Space and Ctrl move you up and down), with a Fly Speed slider
- Enemies Ignore Me
- **CHAOS MODE**: a random effect every few seconds: slow-mo, turbo, giant, tiny, moon gravity, giant
  enemies, shrink ray, bounce house, sonic, berserk

**Achievements**
- Check Achievements: shows how many of the 69 you've unlocked.
- UNLOCK ALL ACHIEVEMENTS (press Enter twice): every Steam achievement in LORT is tied to an in-game
  challenge. This completes them all through the game's own challenge cheat, and the game then unlocks
  the achievements. **This is permanent** and also gives you every challenge reward. Back up your save
  (`%LOCALAPPDATA%\LORT\Saved`) first.

**Actions**
- +1000 Gold, +500 Rune Juice
- Full Heal
- NUKE: kills everything near you
- Kill All Enemies
- Open All Chests
- Give Every Powerup
- Teleport to Boss / Exit / Shop
- Reset All Tweaks

Settings are saved to `LortModMenu\settings.txt` and come back the next time you play.

## How it works
Everything goes through the game's own systems:
- **Stats** are Gameplay Ability System attributes. The menu stores each attribute's original base value and
  writes `original × your setting` with `TrySetAttributeBaseValue`, so the game recalculates everything
  normally. Reset restores the exact original.
- **Cooldowns** are GameplayEffects tagged `Ability.Cooldown` (for example `GE_Cooldown_Wizard_Ignition`,
  which lasts 15 s). The game's cooldown-reduction stat doesn't affect them, so the menu ends each one early by
  removing it once `duration × (1 − reduction)` has passed. Skill 1 uses charges; the menu measures the real
  regen time and refills charges faster.
- **God mode, gold, chests, teleports, powerups and challenges** call the developers' cheat extensions,
  which are still in the shipping game (`BWPlayerCheats`, `BWGameplayCheats`, `BWAICheats`,
  `BWChallengeCheats`).
- **NUKE / Kill All** use the game's own damage function (`ApplyRadialDamage` / `ApplyDamage`).
- **Noclip** switches the character to flying movement and turns off its collision.
- A 250 ms loop keeps applying every tweak, because the game resets stats when you spawn or change level.

**Self-test:** create an empty file `LortModMenu\selftest.flag`. On the next spawn, the menu changes and resets
every tweak and logs the results to `LortModMenu\menu.log`.

## Notes
- Use it in single-player, or in private co-op with friends who agree to it. Not for public lobbies.
- A LORT update can break the UE4SS layout fix. If the game crashes on start, check
  [lort-ue4ss](https://github.com/9vsv6/lort-ue4ss).
- "Damage ×" changes `DamageMultiplier`, which is additive. If the damage numbers don't change much for your
  build, use One-Hit Kills.

## Credits
- Built with an AI coding agent, Claude, using [universal-modder](https://github.com/rehan-remade/universal-modder).
- Runs on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
- No game files are included. MIT license.
