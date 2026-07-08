# Changelog

All notable changes to `pyfsda` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] — unreleased

### Added
- First packaged release of the generic FSDA ↔ Python bridge (`FsdaEngine`, `to_matlab`,
  `from_matlab`), extracted from the `fsda_python_porting_test` prototype.
- Routine-agnostic `call` / `eval` surface with generic marshalling
  (numeric ↔ ndarray, struct ↔ dict, cell ↔ list, char ↔ str, table/timetable → dict,
  2-D cell → nested list) via a MATLAB-workspace round-trip.
- Best-effort FSDA up-to-date check at `start()` (FSDA `tuna`, quiet unless outdated;
  disable with `check_version=False`).

### Publishing note
Releases are published to PyPI via GitHub Actions **trusted publishing** (OIDC) on a `v*` tag.
One-time setup: register `pyfsda` as a Trusted Publisher on PyPI
(project → *Publishing* → add the GitHub repo + `publish.yml` workflow).
