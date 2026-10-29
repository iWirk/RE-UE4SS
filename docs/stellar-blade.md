# Stellar Blade port

This port uses current RE-UE4SS and its pinned UEPseudo/patternsleuth dependencies.
The game profile is in `assets/CustomGameConfigs/Stellar Blade`.

## Build and package

Install Visual Studio 2022 17.13 or newer with C++ tools, CMake, Ninja, and Rust.
Initialize the pinned submodules, then run from the repository:

```powershell
git submodule update --init --recursive
./tools/buildscripts/build-stellar-blade.ps1
```

The default configuration is `Game__Debug__Win64`. For an optimized release build:

```powershell
./tools/buildscripts/build-stellar-blade.ps1 -Configuration Shipping
```

Shipping uses `Game__Shipping__Win64`, with compiler optimization and link-time
optimization, and retains matching PDB symbols. Debug and Shipping use separate
build directories by default.

The script builds UE4SS and the proxy, then creates a fresh directory
under `build/packages/` containing `dwmapi.dll`, `ue4ss/UE4SS.dll`, matching PDBs,
and the Stellar Blade profile merged into current settings. By default the package
contains no `Mods` directory, so installing an update preserves the user's scripts,
`mods.txt`, `mods.json`, and `enabled.txt` markers. For a clean installation only,
pass `-IncludeDefaultMods` to bundle the upstream default mods and load order.
It does not install into the game. Logs are in the build directory. The manifest
records source revisions, local changes, and DLL/PDB SHA-256 hashes.

For an existing local dependency source cache (directories named `fmt-src`, etc.),
pass `-DependencySourceDirectory <directory>`. `-Offline` also uses Cargo's existing
cache. These options are optional; normal builds fetch upstream's declared dependencies.

## Install and verify

1. Exit Stellar Blade. Back up your existing loader and UE4SS files so the previous
   installation can be restored. Keep the installed `ue4ss/Mods` directory in place.
2. Copy the package's `dwmapi.dll` and merge its `ue4ss` folder into `SB/Binaries/Win64`.
   Do not replace the entire installed `ue4ss` folder. The default update package
   intentionally omits `Mods`. Keep the DLL and its matching PDB together.
3. Launch the game. In `ue4ss/UE4SS.log`, verify the packaged configuration
   (`Game__Debug__Win64` or `Game__Shipping__Win64`), engine 4.26,
   the three Lua scan results, completed initialization, and your enabled mods starting.
4. Check console commands, blueprint mod loading, and loading a save.
   Exercise area transitions and outfit changes with your existing mods.
   Those latter checks are needed to investigate the old GC/hook crash reports.

UE4SS starts mods enabled in `mods.txt` or carrying an `enabled.txt` marker; a
folder alone does not enable a mod. Update packages omit `Mods` to preserve the
installed scripts and load order.

Debug builds are unoptimized and include runtime checks; Shipping builds are
optimized. Both retain symbols and use the project's dynamic MSVC runtime.
`DebugBuild = false` and
`Stats = false` describe the **game's** Shipping object layout; they must remain
false when using a Debug UE4SS DLL. Normal upstream hooks and object caching remain
available. The graphical debug UI is disabled so UE4SS creates no additional
graphics window or device for injectors to mistake for the game. The text console,
file logging, crash dumps and debugger symbols remain enabled. Live View and other
GUI-only tools are unavailable in this baseline; mods and game hooks still work.

For an existing installation, change only these settings; no DLL replacement is needed:

```ini
[Debug]
ConsoleEnabled = 1
GuiConsoleEnabled = 0
GuiConsoleVisible = 0
```

Hiding the GUI alone is insufficient: disabling it also prevents the GUI hotkey
from creating a graphics window later. `GraphicsAPI` has no effect while it is disabled.

On a crash, retain `UE4SS.log`, the dump, this package's PDB, and `build-manifest.json`.
Attach Visual Studio or WinDbg to `SB-Win64-Shipping.exe` and break on first-chance
access violations. Set `[CrashDump] FullMemoryDump = 1` if a minidump lacks the
objects needed for diagnosis; full dumps can be several GB. Natvis files are included.

## Compatibility changes and provenance

- Force the game's UE 4.26 Shipping layout while retaining upstream defaults elsewhere.
- Disable the graphical debug UI to prevent graphics injectors from attaching to
  UE4SS's secondary window or graphics device. Text-console logging and debugger
  symbols remain available.
- Port `GUObjectArray` and `GNatives` from SB-UE4SS. Correct the old
  `GUObjectArracy.lua` spelling. Pin GNatives' LEA encoding to RIP-relative RAX;
  repeated initializers are valid when they all resolve to the same table.
- Include `FText_Constructor`, present in the existing Stellar Blade distribution
  (`UE4SS-NEXUS.7z`) but absent from SB-UE4SS's tracked assets.
- Rebuild `VTableLayout.ini` from the current 4.26 template, adding the ten unknown
  AActor virtuals from SB-UE4SS. This retains upstream's renamed overloads and
  avoids the old duplicate `UDataTable::GetRowMap` key. The layout belongs beside
  `UE4SS.dll`, not inside `UE4SS_Signatures`.
- Port only `FUObjectArray::UObjectCreateListeners = 0x68` and
  `UObjectDeleteListeners = 0x78` from the existing distribution's member layout.
  All other members use upstream's generated layout, including its corrected
  `UClass::bCooked` bitfield storage size.
- Fix Lua identifier generation for non-ASCII wide characters in both validation
  and sanitization. The old partial fix dereferenced an empty string and left
  another byte-only character-classification call unsafe.
- Disable UE4SS target IPO for Debug/Dev configurations; retain it for optimized
  configurations when the compiler supports it.
- Serialize UE4SS-managed Lua registry reference allocation and release across
  coroutine stacks. Register callbacks from the caller's stack so async code
  cannot stage values on a hook stack that is executing a game-thread action.
  Keep the shared hook coroutine anchored for the mod's lifetime, independently
  of whichever callback first created it. Invalid callback diagnostics now include
  the reference number and actual Lua type.

The profile retains upstream hook exception handling and object tracking. It does
not include SB-UE4SS's separate save-backup behavior.

## Static validation

```powershell
python tools/tests/stellar_blade_compatibility.py --exe 'C:/path/to/SB/Binaries/Win64/SB-Win64-Shipping.exe'
```

This checks the profile against the current template and scans executable code for
the three overrides. All matches for a signature must resolve to one destination;
global addresses must lie in writable image sections. It reads but does not modify
the executable. These checks establish signature/layout consistency, not gameplay
stability. Runtime verification must use logs produced by this build.

## Lua registry safety and regression test

LuaRaw locks individual API calls, but `luaL_ref` and `luaL_unref` each perform
multiple calls to update the shared registry free list. UE4SS routes reference
allocation and release through one transaction lock, released before executing
Lua callbacks. Native extensions managing references in these states should use
the same `Lua::Registry` helpers; direct raw reference calls do not participate
in this lock. Callers must still own their Lua stack.

Callback registration creates references on the caller's coroutine rather than
modifying the shared hook stack during execution. The indexed `make_ref` overload
preserves arguments for registration paths that reuse them. The mod owns the
shared hook coroutine's registry anchor until its Lua state closes, so removing
one callback cannot expose other callbacks' stack to garbage collection.

After configuring the debug build, run:

```powershell
./tools/tests/run-lua-registry-test.ps1
```

To test the optimized libraries, select the Shipping build directory:

```powershell
./tools/tests/run-lua-registry-test.ps1 -BuildDirectory build/stellar-blade-shipping-ninja
```

The runner rebuilds LuaMadeSimple and links a native test against the production
libraries. Each of its three default runs checks 40,000 unique live callback
references, 12,800 mixed function/boolean references during free-list reuse, and
40,000 overlapping allocations/releases. It also checks callback identity,
registration stack preservation, nil/no-reference handling, and retained coroutine
anchors after collection. Gameplay validation is separate from this regression test.

For runtime confirmation, use the updated DLL and matching PDB with the existing
mods, then repeat save loading, area transitions, and outfit changes. Retain the
new log and any dump if the failure returns. Passing the native test and building
successfully do not establish gameplay stability.
