# fsda_python_porting_test

A small **collaborative prototype** for calling [FSDA](https://github.com/UniprJRC/FSDA) (a MATLAB
robust-statistics toolbox) from **Python** via the MATLAB Engine API — and, in later specs, from
**Julia** and **R**. The goal is to learn how the bridge behaves on real routines, not to ship a
package. Everything is local.

We work **spec-driven**: a shared `CONSTITUTION.md` fixes the rules common to all work, and each unit of
work is one self-contained file under `specs/`. Different people use different agentic AI tools (Claude
Code, Codex, …); a single `AGENTS.md` gives them all the same way of working.

## Repo layout

```
.
├── README.md          ← you are here
├── AGENTS.md          ← unified instructions for any AI agent working in this repo
├── CONSTITUTION.md    ← project-wide contract: port chain, toolchain, marshalling, agreement gate
├── specs/
│   ├── TEMPLATE.md    ← copy this to start a new spec
│   └── 001-*.md       ← one file per spec (Contract + Design + Tasks)
└── code/
    └── <target>/      ← prototype code for each ported FSDA routine
```

## Quickstart

You need:

1. **MATLAB R2026a** with the **FSDA Add-On** installed (so `mahalFS` and friends are on the MATLAB
   path — check with `which mahalFS` inside MATLAB).
2. The shared **Python venv** at `C:\Users\LucaI\fsda_dev_env` (Python 3.12, `numpy`,
   `matlabengine==26.1.*` from PyPI). Override the location with the `FSDA_DEV_VENV` environment
   variable if yours lives elsewhere.

Run the spec 001 worked example:

```powershell
C:\Users\LucaI\fsda_dev_env\Scripts\python.exe code\mahalFS\check_mahalFS.py
```

It starts a MATLAB engine, calls the genuine FSDA `mahalFS`, compares against a pure-numpy reference,
and prints `PASS` when they agree to `< 1e-9`.

## How to work here

1. Read `CONSTITUTION.md` (the rules) and `AGENTS.md` (how agents should behave).
2. Pick an open spec under `specs/`, or copy `specs/TEMPLATE.md` to `specs/NNN-<slug>.md` and write its
   Contract / Design / Tasks.
3. Do the Tasks. Code goes in `code/<target>/`. The **agreement gate** (match FSDA to tolerance) is the
   definition of done.
4. Commit in scoped chunks; reference the spec number.
