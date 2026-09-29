# Live regression checks

Run from the repository in PowerShell with the survivor alive and the game paused.
These scripts exercise the loaded bot; they restore overridden bot state and avoid
queuing movement. Do not run alongside a gameplay command waiting for completion.

```powershell
python pz.py eval (Get-Content 'tests/resume_after_combat.lua' -Raw)
python pz.py eval (Get-Content 'tests/window_target.lua' -Raw)
python pz.py eval (Get-Content 'tests/combat_stall.lua' -Raw)
python pz.py eval (Get-Content 'tests/injury_before_resume.lua' -Raw)
python pz.py eval (Get-Content 'tests/failed_task.lua' -Raw)
python pz.py eval (Get-Content 'tests/covered_bite.lua' -Raw)
```

All should print `PASS` in the eval result. The window test requires the loaded
Rosewood kitchen at 8177,11673,0, with both its frame and actual window intact.
It captures queued actions to check their real target without opening or climbing.

Diagnostic error smoke checks:

```powershell
python pz.py eval "error('intentional eval failure regression')"
python pz.py eval "R=nil"
python pz.py eval "R='probe completed'"
```

The first must print `ERR eval: eval did not complete`; its console stack trace is
expected. The other two must print successful `nil` and `probe completed` results.
The driver currently returns process exit code 0 even for command-level errors;
inspect `results[].ok` in state.json rather than trusting the process exit code.

Observed before fixes: combat queued a deferred walk then immediately ended the
turn; window actions targeted an IsoWindowFrame despite an IsoWindow on the same
tile; a failing eval misleadingly printed `ok eval: nil`.
