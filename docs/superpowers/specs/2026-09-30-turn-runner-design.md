# Turn runner: ClaudeBot owns its queue

## Problem
A turn loads every line into the game's timed-action queue up front: one `ClaudeBotStep` per line.
The game treats that queue as disposable:
- window, climb and fall states wipe it when they end;
- fights and reflexes clear it;
- a failed walk force-stops it.

None of these says what was lost. The engine then reconstructs what happened from shared flags:
`pending`, `pendingIdx`, `resumeFrom`, `failedIdx`, `autoResumed`, `deferred`, `watches`, and the
task's `resumeFrom`. Every bug fixed on 2026-09-30 was an interaction between those flags:
- auto-resume after a failure;
- lines starting mid-animation;
- watches overwriting each other.

## Design
ClaudeBot keeps its own list of the turn's lines and runs them **one at a time**. The game's queue
only ever holds the current line's actions.

### Data
`B.run = { lines = { {text, verb, args, status, msg, tries, check} ... }, cur = i }`

`status` is one of `waiting | running | done | failed | notrun`.

### The runner (`B.runTick(p)`, called from `B.monitor` after the safety checks and reflexes)
1. **Hold** while anything else owns the character:
   - a fight, flee or bash;
   - a busy player state (window, climb, fall, get-up);
   - a running goal task (`travel`, `home`, `sweep`...);
   - sleep.
2. **Start** the current `waiting` line: run the command function directly, in a `pcall`, against an
   empty game queue.
   - An error fails the line.
   - An instant command (`look`, `find`, `fort`...) is `done` straight away with its message.
   - A goal command starts its task. The line stays `running` until `B.finishTask` reports.
3. **Judge** a `running` line once the game queue is empty and has been empty for 600 ms:
   - It has a `check` (window open/close/climb, and later others): run it. `ok` → `done`,
     error → `failed`, with the reason.
   - A failure was already recorded for it (e.g. PATH FAILED, couldn't walk there) → `failed`.
   - Its end marker ran: `done`. The marker is a tiny action queued after the line's own actions,
     including its existing `take`/`loot`/`craft` check steps.
   - Otherwise it was **cut short** by a wipe that recorded no failure: run it again once
     (`tries < 2`), then fail it with "interrupted before it finished".
4. **Advance:**
   - `done` → next line.
   - `failed` → every later line becomes `notrun` ("NOT RUN: '<line>' failed"), and the turn ends.
   - No lines left → the turn ends `done` (after `B.upkeep`, as now).

### Interruptions
- `B.interrupt(p)` (reflex fight, rearm, flee, weapon recovery) clears the game queue and marks the
  current line `waiting` again, so the runner starts it again once the reflex is over. This is today's
  "re-run the interrupted line" behavior, without `resumeFrom`.
- `continue` as the first line of a new turn keeps the unfinished `B.run` and carries on from `cur`.
  Any other first line starts a fresh run.

### What goes away
- `ClaudeBotStep`, its hold in `update()`, and its task check in `perform`.
- `B.deferred` and the one-tick defer in `B.monitor`.
- `B.pending`, `pendingIdx`, `resumeFrom`, `failedIdx`, `autoResumed`.
- `B.resumePending`, and the auto-resume block at the end of `B.monitor`.
- `B.watches` / `watchTick`: a window's judge becomes that line's `check`.
- `startTask`'s `resumeFrom`: the runner simply holds while a task runs.

### What stays
- Every command function, unchanged. They still `Q()` their actions; the queue is simply empty when
  they run.
- The existing check steps (`B.verifyTaken`, craft and barricade checks) stay, as the line's last
  actions, with their result lines.
- `B.lineFailed`, and the walk-failure hook (it marks the current line).
- `B.results` and the `state.json` / `pz.py` formats. The driver doesn't change.

### Known risk
A line whose work finished, but whose end marker was wiped by a state that started afterwards, gets
re-run once. That's harmless for `go`, `take` and `loot` (they skip what's already done) and for `put`.
Window lines are judged by their `check`, not the marker. `eat`, `drink` and `craft` don't trigger
wiping states, so they aren't expected to hit this. If a test shows otherwise, they get a `check`.

## Behavior changes players will see
- **A line that is wiped mid-way now runs again once**, then fails with a reason. Before, the next
  line ran, or the queue was silently dropped.
- **Every result line stays in order**, one line at a time. Today the check lines of window actions
  arrive after later lines.

## Testing
- Rewrite the live tests that poke engine internals against `B.run`:
  `failed_walk`, `resume_after_combat`, `failed_task`, `injury_before_resume`, `combat_stall`.
- `covered_bite`, `window_target` and `floor_default` should pass unchanged.
- New tests:
  - a failed line stops the rest;
  - a line cut short by a wipe runs again, then fails with a reason;
  - `continue` resumes at the right line.
- Live, in the game:
  - `open`, `climb`, `climb`, `close` in one turn;
  - a `take` from an unreachable container;
  - `go`, `loot` and `home` in one turn;
  - a reflex fight mid-`go` (it carries on walking afterwards).
- A pz-player run afterwards, compared against the v0.5.0 turn log for errors and NOT RUN lines.

## Out of scope
- Moving the check steps (`verifyTaken`, etc.) into `check` functions. They work as queued steps.
- Changes to goal-task internals.
