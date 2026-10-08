# LORT Menu

An in-game mod menu for **LORT**, with gameplay tweaks, fun extras, hotkeys and an achievement unlocker. It's a
UE4SS Lua mod.

**Requires** UE4SS with the LORT layout fix: [LORT-UE4SS](https://github.com/9vsv6/LORT-UE4SS).

> ⚠️ **Co-op: the menu only works when YOU are the host.**
> In LORT the host's game is the server and has the final say on health, damage, cooldowns, items, gold,
> spawning and so on. The developer cheats the menu uses also run on the host only. If you **join** a friend's
> game, the options won't do anything, because the host's game overwrites them. To use the menu together, **the
> host installs the mod**. The menu doesn't try to force changes into someone else's server.
> Solo play always works.

## Install
1. Install UE4SS and the layout fix by following [LORT-UE4SS](https://github.com/9vsv6/LORT-UE4SS).
2. Copy the `LortModMenu` folder into `...\LORT\bw\Binaries\Win64\ue4ss\Mods\`.
3. Add this line to `ue4ss\Mods\mods.txt`, above the `Keybinds` line:
   ```
   LortModMenu : 1
   ```
4. Launch LORT and press **F1** (or Insert).

## Using the menu
**Mouse**
- Click a section in the left sidebar.
- Click a switch to toggle it, and click a RUN pill to run an action.
- **Click or drag on a slider's bar** to set its value, or use **−** and **+** (hold them to repeat).
- **Drag the top edge or a title** to move the window.
- **Drag any corner or edge** to resize it. The cursor shows resize arrows; wider makes the rows wider, and
  taller shows more rows.
- Scroll long sections with the **mouse wheel**.
- **X** (top right) closes the menu.

The cursor appears and camera look is paused while the menu is open. Position and size are saved, and
**Settings → Reset Menu Position & Size** brings the window back.

**Keyboard**

| Key | Action |
|---|---|
| F1 / Insert | Open or close, anywhere including the main menu (the menu key can be changed in Settings) |
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
- **Projectile Size** ×1–5: your arrows, orbs, daggers, bombs and mines get bigger, with bigger hitboxes and
  explosions
- **Melee Range** ×1–4: your swings hit a bigger area, further out (enemy attacks unchanged)

**Fun**
- **Custom FOV** + FOV Angle 60–150
- Game Speed ×0.1–3
- Player Size
- Gravity
- Jump Height
- Enemy Size
- **Noclip**: fly through walls (Space and Ctrl move you up and down), with a Fly Speed slider
- Enemies Ignore Me
- **Big Head Mode** with a Head Size slider (your hero)
- **CHAOS MODE**: a random effect every few seconds: slow-mo, turbo, giant, tiny, moon gravity, giant
  enemies, shrink ray, bounce house, sonic, berserk

**Model**: wear any character model in the game
- A grid of every character model that's loaded: all heroes (Wizard, Warrior, Ranger, Rogue, Paladin), camp NPCs,
  and the enemies near you during a run. Click one to wear it.
- The model copies your selected hero's animations (leader pose), so it walks, attacks and uses skills like your
  hero. Your weapons stay in your hands.
- It stays on after you respawn or change level. Use **Back To My Hero** to undo, or **Wear Random Model**.

**Run**
- Next Level, Skip To Level 1–8, Teleport to Boss / Exit / Shop, Complete Landmark, End Run (extract),
  Restart (die).

**Weapons, Items, Monsters**: spawners with clickable tile grids
- **Weapons:** all 22 weapons (click to get one), Item Level 1–30, Give All, Random Weapon.
- **Items:** all 105 powerups plus keys, toys, quest items and trash; Random Powerup, 5 Random, Every Powerup.
- **Monsters:** all 56 enemies and bosses (click to spawn near you), Spawn Count 1–20, Spawn Random Boss,
  Kill Everything.

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
- **Spawners**: item IDs are the row names of the game's DataTables (`PlayerItems_Equipment`, `PowerupsTable`,
  `NPCTable`). They were read from memory with `tools/rowdump.py`, and given with the dev cheats
  `AddItemToInventory`, `GivePowerup` and `Spawn`.
- **Model**: a second `SkeletalMeshComponent` is added with `AddComponentByClass` and attached to the hero mesh,
  using `SetLeaderPoseComponent(hero)`. The hero mesh is hidden but keeps ticking
  (`VisibilityBasedAnimTickOption = AlwaysTickPoseAndRefreshBones`).
- **Big Head** retargets a `FAnimNode_ModifyBone` node in `ABP_Player` to the `Head` bone, then bounces the mesh
  LOD so the anim graph re-caches its bone references.
- **Attack size**: player projectiles (`ABWProjectile`, instigator = you) get an actor scale and a bigger
  `DamageRadius`. Player melee notifies (`BWAnimNotify_MeleeAttack`) get their `FBWDamageShape` scaled.
- **FOV** uses `PlayerController:FOV(angle)`.
- **Noclip** switches the character to flying movement and turns off its collision.
- **Unlock persistence.** `CompleteAllChallenges` fires the Steam achievements, but the game never writes the
  completion into its profile save, so the unlocks reset. The save is JSON
  (`%LOCALAPPDATA%\LORT\Saved\SaveGames\<SteamID>\ProfileN*.sav`):
  - `completedChallenges` is a list of challenge GUIDs;
  - `unlocks.items/powerups/skins/...` are `{iD, guid}` entries, where the guid is the GUID of the granting
    challenge.

  The game rewrites that file from memory while it runs, so the menu records what to add and patches the save
  on the next launch, before the game reads it. A copy of the old save is kept in the mod folder.
- **The look**: a `BackgroundBlur` widget under a translucent rounded `Border`. Rounded corners come from editing
  each brush in place (`DrawAs = RoundedBox` with corner radii). The sidebar icons are white PNGs in
  `LortModMenu/icons`, drawn with `tools/make_icons.py` and loaded at runtime with `ImportFileAsTexture2D`.
- **The window frame** is an `Overlay` with invisible grab areas on every edge and corner (`SetCursor` gives
  them Windows resize cursors). Resizing changes the row width and list height, and the left and top edges
  also move the window.
- **The menu UI** is UMG widgets created from Lua. UE4SS Lua can't bind UMG click delegates, so buttons are
  polled every frame (`IsPressed`), and a press followed by a release counts as a click.
- **Threading.** Everything runs from one `LoopInGameThreadWithDelay` loop on the game thread. Running Lua from
  UE4SS's async threads (`LoopAsync`, keybind callbacks) at the same time as the game thread corrupted the Lua
  state and crashed UE4SS. Keys are read with `PlayerController:IsInputKeyDown` for the same reason.
  - **Exception: the menu key and key capture** use UE4SS `RegisterKeyBind`. `IsInputKeyDown` can't see keys
    while the game's own UI owns input (the main menu). Those callbacks only queue a function onto the game
    thread, once per key press.
  - When the menu opens, `SetFocusToGameViewport` keeps the keyboard with the game, so keys still work while the
    mouse uses the menu.

**Self-test:** create an empty file `LortModMenu\selftest.flag`. On the next spawn, the menu changes and resets
every tweak and logs the results to `LortModMenu\menu.log`.

## Notes
- **Host only in co-op** (see the top of this page).
- **Less-tested features:**
  - Big Head, Run Control and the Monster spawner were built against the game's code but have had little
    play-testing;
  - non-hero models only animate where their bone names match the hero skeleton.

  Please open an issue if something doesn't work.
- Use it in single-player, or in private co-op with friends who agree to it. Not for public lobbies.
- Pick hotkeys the game doesn't use (F2–F12, numpad, Home/End, side mouse buttons). A hotkey still does its
  normal in-game action too.
- A LORT update can break the UE4SS layout fix. If the game crashes on start, check
  [LORT-UE4SS](https://github.com/9vsv6/LORT-UE4SS).
- "Damage ×" changes `DamageMultiplier`, which is additive. If the damage numbers don't change much for your
  build, use One-Hit Kills.

## Credits
- Built with an AI coding agent, Claude, using [universal-modder](https://github.com/rehan-remade/universal-modder).
- Runs on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
- No game files are included. MIT license.
