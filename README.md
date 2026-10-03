# LORT Mod Menu

An in-game mod menu for **LORT**, with gameplay tweaks, fun extras, hotkeys and an achievement unlocker. It's a
UE4SS Lua mod.

The menu is a real in-game window built from UMG widgets in LORT's own font. It has tabs, and it works with
**mouse and keyboard**: you can **drag** it and **resize** it.

**Requires** UE4SS with the LORT layout fix: [lort-ue4ss](https://github.com/9vsv6/lort-ue4ss).

## Install
1. Install UE4SS and the layout fix by following [lort-ue4ss](https://github.com/9vsv6/lort-ue4ss).
2. Copy the `LortModMenu` folder into `...\LORT\bw\Binaries\Win64\ue4ss\Mods\`.
3. Add this line to `ue4ss\Mods\mods.txt`, above the `Keybinds` line:
   ```
   LortModMenu : 1
   ```
4. Launch LORT and press **F1** (or Insert).

## Using the menu
**Mouse**
- Click a tab.
- Click a toggle or its ON/OFF pill to flip it, and click an action or its RUN pill to run it.
- Use **<** and **>** on sliders. Hold them to repeat.
- **Drag the title bar** to move the window.
- **Drag the // grip** in the bottom-right corner to resize it.
- Scroll long tabs with the **mouse wheel**.
- **X** closes the menu.

The cursor appears and camera look is paused while the menu is open.

**Keyboard**

| Key | Action |
|---|---|
| F1 / Insert | Open or close (the menu key can be changed in Settings) |
| Up / Down | Select |
| Left / Right | Change a value (hold to repeat) |
| PgUp / PgDn | Switch tab |
| Enter | Toggle, or run an action |
| Delete | Reset the selected tweak, or clear the selected hotkey |
| Numpad 8 2 4 6 5 7 9 | Same as the keys above |
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
- **Skill Speed** ×1–10 / INSTANT: skill and attack animations play faster, so they fire sooner
- Crit Chance
- Crit Damage
- **Cooldown Reduction** 0–100% (100% = no cooldowns for skills and weapon alt-fires)

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

**Actions**
- +1000 Gold, +500 Rune Juice
- Full Heal
- NUKE: kills everything near you
- Kill All Enemies
- Open All Chests
- Give Every Powerup
- Teleport to Boss / Exit / Shop
- Reset All Tweaks

**Achievements**
- Check Achievements: shows how many of the 69 you've unlocked.
- **UNLOCK ALL ACHIEVEMENTS** (press Enter twice): unlocks all Steam achievements, completes every challenge
  and gives you every challenge reward (classes, weapons, powerups and skins).
  **Restart the game afterwards.** The unlocks are written into your profile save at the next launch. This
  is permanent.

**Settings**
- Menu Key: rebind F1 to any key.
- Menu Size: 50–200%. You can also drag the // grip.
- Reset Menu Position & Size.
- **A hotkey for every feature.** Each toggle and action has its own row (`Hotkey: God Mode`). Click a row and
  press a key to bind it. Esc cancels, and Backspace or Delete clears it. Hotkeys work with the menu open or
  closed, and bound features show their key next to their name.
- Clear All Hotkeys.

Settings, hotkeys and the window position and size are saved to `LortModMenu\settings.txt`.

## How it works
Everything goes through the game's own systems:
- **Stats** are Gameplay Ability System attributes. The menu stores each attribute's original base value and
  writes `original × your setting` with `TrySetAttributeBaseValue`, so the game recalculates everything
  normally. Reset restores the exact original.
- **Cooldowns** are GameplayEffects tagged `Ability.Cooldown` (for example `GE_Cooldown_Wizard_Ignition`,
  which lasts 15 s). The game's cooldown-reduction stat doesn't affect them, so the menu removes each one once
  `duration × (1 − reduction)` has passed. Skill charges are refilled faster in the same proportion.
- **Skill Speed** changes the play rate of the active animation montage (`Montage_SetPlayRate`). Dodge rolls
  are skipped, so they keep their distance.
- **God mode, gold, chests, teleports, powerups and challenges** call the developers' cheat extensions,
  which are still in the shipping game (`BWPlayerCheats`, `BWGameplayCheats`, `BWAICheats`,
  `BWChallengeCheats`).
- **NUKE / Kill All** use the game's own damage function (`ApplyRadialDamage` / `ApplyDamage`).
- **Noclip** switches the character to flying movement and turns off its collision.
- **Unlock persistence.** `CompleteAllChallenges` fires the Steam achievements, but the game never writes the
  completion into its profile save, so the unlocks reset. The save is JSON
  (`%LOCALAPPDATA%\LORT\Saved\SaveGames\<SteamID>\ProfileN*.sav`):
  - `completedChallenges` is a list of challenge GUIDs;
  - `unlocks.items/powerups/skins/...` are `{iD, guid}` entries, where the guid is the GUID of the granting
    challenge.

  The game rewrites that file from memory while it runs, so the menu records what to add and patches the save
  on the next launch, before the game reads it. A copy of the old save is kept in the mod folder.
- **The menu UI** is UMG widgets created from Lua. UE4SS Lua can't bind UMG click delegates, so buttons are
  polled every frame (`IsPressed`), and a press followed by a release counts as a click.
- **Threading.** Everything runs from one `LoopInGameThreadWithDelay` loop on the game thread. Running Lua from
  UE4SS's async threads (`LoopAsync`, keybind callbacks) at the same time as the game thread corrupted the Lua
  state and crashed UE4SS. Keys are read with `PlayerController:IsInputKeyDown` for the same reason.

**Self-test:** create an empty file `LortModMenu\selftest.flag`. On the next spawn, the menu changes and resets
every tweak and logs the results to `LortModMenu\menu.log`.

## Notes
- Use it in single-player, or in private co-op with friends who agree to it. Not for public lobbies.
- Pick hotkeys the game doesn't use (F2–F12, numpad, Home/End, side mouse buttons). A hotkey still does its
  normal in-game action too.
- A LORT update can break the UE4SS layout fix. If the game crashes on start, check
  [lort-ue4ss](https://github.com/9vsv6/lort-ue4ss).
- "Damage ×" changes `DamageMultiplier`, which is additive. If the damage numbers don't change much for your
  build, use One-Hit Kills.

## Credits
- Built with an AI coding agent, Claude, using [universal-modder](https://github.com/rehan-remade/universal-modder).
- Runs on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
- No game files are included. MIT license.
