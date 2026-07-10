# Feature: Claude Touch Bar Pet — Local MVP

## Summary

Turn the existing Claude Code completion mascot into a local electronic pet. A
successful user prompt produces one gameplay work event (rendered as two visual
hops). Main-agent and subagent token usage are aggregated for that prompt and
drive hunger and stamina. Players can feed and put the pet to sleep, but cannot
manually trigger work/jump events.

This MVP is local-only. Payments, accounts, and a server-authoritative food
balance are intentionally deferred, while the state schema remains versioned so
they can be added later.

## Confirmed Rules

- Stats: age, health, hunger, stamina.
- New pet: health 100, hunger 20, stamina 100.
- One successful user prompt triggers one gameplay work event and two visual
  hops. User interruption and failed API turns do not count.
- Subagent token usage is included in the parent prompt; subagents do not create
  additional work events.
- Effective token workload:

  ```text
  E = output
    + 0.20 * uncached_input
    + 0.25 * cache_creation
    + 0.02 * cache_read
  ```

- Token hunger: `E / 30,000`, with at most 150 token-hunger per local day.
- Work stamina cost:

  ```text
  clamp(0.5 + 1.5 * log2(1 + E / 2,000), 0.5, 8), rounded to 0.5
  ```

- A work event grants health +0.5 when stamina is available, capped at +3 per
  local day.
- `feed` reduces hunger by 30. The first three successful feeds each local day
  are free. When those are exhausted, the local MVP reports that paid food is
  not implemented.
- Feeding below 10 hunger is refused without consuming a free feed.
- Natural hunger: +0.5/hour awake, +0.25/hour sleeping.
- Awake stamina decay: -2/hour. Sleeping restores +12.5/hour.
- Manual sleep auto-wakes after eight hours. macOS system sleep and app shutdown
  count as sleep for their full duration.
- At hunger 100 the pet enters starving state. While starving, health decreases
  by 2/hour; feeding can rescue it.
- Remaining awake beyond 20 hours decreases health by 0.5/hour. Remaining at
  zero stamina decreases health by 0.5/hour.
- More than 36 hours without a successful work event decreases health by
  0.1/hour.
- Health 0 is death. A dead pet rejects feed/sleep/work and can only restart via
  `clawd hatch`; age freezes and longest lifetime is retained.

## CLI

```text
clawd status
clawd feed
clawd sleep
clawd wake
clawd hatch
clawd view show|hide|auto
clawd _record-stop        # internal Claude Code Stop hook command
```

The public manual `clawd jump` command is removed. Existing Touch Bar display
mode is moved under `clawd view` so sleep/wake can represent pet state.

## Architecture

- `PetState`: versioned Codable facts only; age and presentation state are
  derived.
- `PetRules`: all balance constants and token formulas.
- `PetEngine`: deterministic time advancement and actions.
- `PetStore`: locked, atomic JSON persistence under
  `~/.claude-touchbar/pet-state.json`; supports a test data-directory override.
- `TranscriptUsage`: extracts only identifiers and usage counters, never stores
  prompt/response text, deduplicates repeated assistant blocks by message ID,
  and aggregates the parent prompt plus subagents.
- `StopEventQueue`: keeps only session/prompt IDs, transcript path, and retry
  timestamps for one minute so late asynchronous-agent usage can be applied as
  a positive delta without producing another work event or bounce.
- `PokeSignal`: uses one durable queue file per visual reminder, so completions
  inside the same UI polling interval still play as separate two-hop animations.
- `PetCLI`: command routing and user-facing status.
- Existing AppKit helper: observes system sleep/wake, refreshes the compact pet
  status, and keeps the edge-triggered Touch Bar presentation behavior.

## Failure and Privacy Rules

- Stop handling is idempotent by `session_id + prompt_id`.
- Transcript parsing retries briefly for asynchronous transcript writes. If
  usage is still unavailable, the visual reminder remains functional and the
  event is not double-charged.
- Corrupt state is preserved and reported; it must not silently hatch a new pet.
- State and lock files are private to the current user.
- No conversation text, prompts, responses, tokens, or telemetry leave the Mac.

## Implementation Tasks

- [x] **Implement pet rules and deterministic engine** `priority:1` `phase:model` ✅
  - files: Sources/ClaudeTouchBar/PetState.swift, Sources/ClaudeTouchBar/PetRules.swift, Sources/ClaudeTouchBar/PetEngine.swift, Tests/PetCoreTests.swift, scripts/test.sh
  - [x] Feed, work, sleep, wake, hatch, daily reset, and clamping rules are covered by tests
  - [x] Starvation, exhaustion, lack-of-sleep, inactivity, auto-wake, and death are covered by tests
  - [x] Token hunger and stamina formulas match the confirmed constants

- [x] **Add private atomic pet persistence** `priority:2` `phase:model` `deps:Implement pet rules and deterministic engine` ✅
  - files: Sources/ClaudeTouchBar/PetStore.swift, Tests/PetCoreTests.swift
  - [x] State transactions are protected by a cross-process lock
  - [x] JSON writes are atomic and files use private permissions
  - [x] A test data-directory can be supplied without touching the real pet
  - [x] Corrupt state produces an explicit error instead of a silent reset

- [x] **Aggregate prompt and subagent token usage** `priority:3` `phase:model` `deps:Add private atomic pet persistence` ✅
  - files: Sources/ClaudeTouchBar/TranscriptUsage.swift, Tests/PetCoreTests.swift
  - [x] Usage is scoped to one prompt and repeated assistant blocks are deduplicated
  - [x] Main-agent and available subagent usage are included exactly once
  - [x] Sidechain/unrelated prompt records are excluded

- [x] **Implement local pet CLI and idempotent Stop handling** `priority:4` `phase:api` `deps:Aggregate prompt and subagent token usage` ✅
  - files: Sources/ClaudeTouchBar/PetCLI.swift, Sources/ClaudeTouchBar/main.swift, Sources/ClaudeTouchBar/PokeSignal.swift, Tests/PetCoreTests.swift
  - [x] status/feed/sleep/wake/hatch/view commands work against an isolated test directory
  - [x] Manual jump is unavailable
  - [x] `_record-stop` reads hook JSON, settles one prompt once, and triggers the visual poke

- [x] **Integrate pet state into the Touch Bar helper** `priority:5` `phase:ui` `deps:Implement local pet CLI and idempotent Stop handling` ✅
  - files: Sources/ClaudeTouchBar/AppDelegate.swift, Sources/ClaudeTouchBar/ClaudeLogoView.swift, Sources/ClaudeTouchBar/TouchBarPresenter.swift
  - [x] Touch Bar text reflects normal, hungry, tired, sleeping, starving, and dead states
  - [x] macOS sleep/wake and helper shutdown count as pet sleep
  - [x] Existing edge-triggered presentation behavior remains intact

- [x] **Migrate installer hook and document the MVP** `priority:6` `phase:docs` `deps:Integrate pet state into the Touch Bar helper` ✅
  - files: scripts/configure_stop_hook.py, scripts/install_launch_agent.sh, scripts/uninstall_launch_agent.sh, README.md
  - [x] Existing poke-only hook is replaced idempotently with `_record-stop`
  - [x] Install and uninstall instructions match the new commands
  - [x] README explains local-only food limits, token accounting, sleep, death, and test commands

- [x] **Build, test, install, and smoke-test locally** `priority:7` `phase:test` `deps:Migrate installer hook and document the MVP` ✅
  - files: scripts/build.sh, scripts/test.sh
  - [x] Core tests pass
  - [x] Production helper builds successfully
  - [x] LaunchAgent and Stop hook are updated
  - [x] Installed `clawd status` and display controls work without consuming a feed
