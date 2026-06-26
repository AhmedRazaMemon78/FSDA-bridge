# AGENTS.md

Instructions for **any** AI agent (Claude Code, Codex, …) working in this repo. One file, one way of
working — vendor-agnostic. If your tool looks for a different filename, point it here.

## Workflow

1. **Read `CONSTITUTION.md` first.** It is the contract common to every spec — toolchain, bridge
   architecture, marshalling rules, the agreement gate. Do not override it without the author's sign-off.
2. **Work inside a spec.** Every change belongs to a file under `specs/` (`NNN-<slug>.md`, with
   `Contract` + `Design` + `Tasks` sections). Don't start code that isn't covered by an open spec —
   if there's no spec, copy `specs/TEMPLATE.md` and write one first.
3. **Execute the Tasks** in order, checking them off in the spec file as you go.
4. **The agreement gate is the definition of done** — see below.

## Code style

- **Python:** PEP 8; small, flat functions (avoid deep nesting); type hints on the bridge surface.
  Dependencies are `numpy` + `matlab.engine` + the standard library only — no heavy frameworks.
- **R** (later specs): `=` for assignment, never `<-`; `snake_case`; one statement per line.
- **Julia** (later specs): standard Julia conventions; PythonCall for the bridge.
- **MATLAB / FSDA:** never edit. We *call* FSDA; we don't modify it. Any `.m` we add is a minimal
  reference-driver only.

## The agreement gate (law)

Every port must reproduce the genuine FSDA output to a stated tolerance (default `1e-9`): same values,
same flagged units, same structure — accounting for legitimate equivalent-optimum / ordering ambiguity.
The FSDA call is the **reference oracle**; gold outputs are saved under the target's folder. A port that
hasn't been checked against the oracle is not done.

## Discipline

- Keep commits **scoped** and reference the spec number (e.g. "spec 001: bridge.py + check").
- When a task closes, check it off in the spec file; jot a one-line dated note if anything was learned.
- Don't add a package build, CI, or new dependencies — this is a local prototype.
