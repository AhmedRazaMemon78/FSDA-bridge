# Spec 013 — MATLAB Engine: call FSDA `getYahoo` from Python (Yahoo Finance time series)

> Fifth function ported through the Layer-1 bridge, after `mahalFS` (001), `Score` (004), `FSR` (007)
> and `FSRaddt` (010). `getYahoo` is the richest crossing yet: called with **several tickers** it returns
> a MATLAB **struct array** (one element per ticker), each element carrying a MATLAB **timetable**
> (`out.TT`) and a nested **Indicators** struct, and it pulls **live data over the network**. Read
> `CONSTITUTION.md` first. Python surface only; Julia (014) and R (015) are siblings.

## Contract

- **Deliverable:** from Python, start a MATLAB engine session, call the genuine FSDA
  `getYahoo({'G.MI','ENEL.MI'}, 'plots', P, 'msg', M)`, and return one dict per ticker (the struct-array
  crossing) — `Ticker`, `LastPeriod`, `intervalRequested`, `intervalActual`, `TimeZone`, `TT`
  (`{time, Open, High, Low, Close, Volume}`), `Indicators` (11 arrays), `Success`, `Message`, `class`.
- **Done when:** `code/getYahoo/check_getYahoo.py`, run with the project venv, prints `PASS` — **the
  fixed-window OHLCV row for both tickers equals the committed golden** (`reference/getYahoo_window.csv`)
  to `< 1e-9`. The window is a 1-second `timerange` over a **past** bar, so its values are deterministic
  even though `getYahoo` downloads live data (see below).
- **Out of scope:** Julia and R surfaces (014 / 015); an independent numpy oracle (impossible — the data
  is live Yahoo); the plot suboptions (`topPanelMode` / `bottomPanelMode` structs, layout & indicator
  styling); gating the full `TT` / `Indicators` body (only the fixed window is gated; the rest is
  transparency); FSDA routines other than `getYahoo`; packaging.

## Design

**Why the gate is a fixed `timerange` window, not a frozen golden of the whole series.** `mahalFS` /
`Score` had clean pure-numpy oracles; `FSR` / `FSRaddt` had a deterministic forward-search golden.
`getYahoo` has **neither** — it issues a `webread` to `query1.finance.yahoo.com`, so the series changes
every call (at minimum the latest bar) and an FSR-style frozen golden would FAIL by construction. The
fix (per the project owner): gate on the OHLCV of a **single past bar**, isolated by a 1-second
`timerange`. A finalized historical bar no longer moves, so the value is deterministic across runs and
across the three surfaces. The mandated MATLAB gate code, run verbatim by the bridge, is:

```matlab
T1 = out(1).TT;  tr = timerange("23-Jun-2026 09:00:00","23-Jun-2026 09:00:01");
T1(tr,:)                                          % and likewise for out(2).TT
```

**Determinism & the window-aging caveat.** The fixed call uses getYahoo's **default** `LastPeriod` /
`interval` (the owner's first call `getYahoo({'G.MI','ENEL.MI'},'plots',1)`); whatever granularity that
resolves to, the 1-second window isolates one bar whose timestamp falls inside it. The bar is only
retrievable while it remains in Yahoo's retention for that granularity. If the live download succeeds but
the window is empty (bar aged out), the check FAILs with a "refresh `t0`/`t1`" hint. If Yahoo is
unreachable (no `Success` for any ticker), the check prints **SKIP** and exits 0 — a transient outage is
not a code defect. `plots`/`msg` default to 0 in the bridge (headless gate); the check sets them on
(parity with FSR `PLOTS=MSG=1`) to open one three-panel figure per ticker.

- **Files:**
  - `code/getYahoo/bridge.py` — Layer 1. `start_engine(fsda_root=None)` (verify `which('getYahoo')`),
    `get_yahoo(eng, tickers, plots=0, msg=0, last_period=None, interval=None, auto_fix_interval=None)`
    (builds a validated MATLAB call, leaves `out` in the base workspace, decomposes the struct array
    field-by-field → list of dicts), `timerange_window(eng, idx, t0, t1)` (runs the owner's snippet,
    returns the bar's `{time, OHLCV}`), `render_figures` / `wait_for_figures`, `stop_engine`, plus
    diagnostics `matlab_version` / `which_getyahoo` for the Layer-2 surfaces.
  - `code/getYahoo/check_getYahoo.py` — the agreement check. Fixed input = `{'G.MI','ENEL.MI'}` + the
    window endpoints, read from `reference/getYahoo_query.json` (bootstrapped on first run). Gate = the
    fixed-window OHLCV for both tickers vs golden at `atol=1e-9`. Bootstraps
    `reference/getYahoo_window.csv` (golden, `ticker,time,Open,High,Low,Close,Volume`) on first run;
    also writes `reference/getYahoo_check.csv` (per-ticker `Success` / `intervalActual` / `TimeZone` /
    `TT` height / indicator count, for transparency).
- **Signatures / shapes:** `tickers` is a `str` or iterable of `str`; returns `list[dict]` of length
  `numel(out)`. Each `TT` is `{time: list[str] (ISO 8601 w/ zone), Open/High/Low/Close/Volume: (n,)}`;
  `Indicators` is a dict of 11 `(n,)` arrays. `timerange_window` returns a TT dict for the matched bar(s).
- **Marshalling notes (where `getYahoo` breaks ports — five new wrinkles vs FSR/FSRaddt):**
  - *Struct ARRAY return (new):* `getYahoo` with k tickers returns a `k×1` MATLAB **struct array**; the
    engine does not hand a non-scalar struct array back as a clean dict, so the bridge keeps `out` in the
    workspace and decomposes `out(ii)` with `eng.eval` into a **list of dicts** — the first array-of-
    structs crossing in the repo.
  - *Timetable → time + matrix (new):* `out.TT` is a MATLAB **timetable**, which does not marshal.
    Decomposed MATLAB-side: row-times via `cellstr(string(TT.Time,'yyyy-MM-dd HH:mm:ssZ'))` → `list[str]`,
    body via `TT.Variables` → `(n,5)` numeric. Shape-checked (`width==5`, `len(time)==n`); no reshape.
  - *Timezone-aware datetime → ISO string (new):* the row-times are zoned datetimes (exchange tz);
    crossed as ISO 8601 strings with offset, never as opaque datetime objects.
  - *Nested struct → dict:* `out.Indicators` is a nested struct of 11 numeric vectors → dict of arrays
    (NaN-preserving), each length-checked against `height(TT)`.
  - *`string` scalar → str:* `Ticker` / `LastPeriod` / `intervalActual` / `TimeZone` / `Message` are
    MATLAB `string` scalars; wrapped with `char(...)` before crossing so they arrive as `str`.
  - *Safety:* ticker / option / datetime strings are interpolated into `eng.eval` commands, so each is
    validated against a strict allow-list before use.
- **Reference oracle:** the genuine FSDA `getYahoo` run; the fixed-window OHLCV golden saved to
  `code/getYahoo/reference/getYahoo_window.csv`, the shared input to `reference/getYahoo_query.json`.

## Tasks

- [ ] #p1 Write `code/getYahoo/bridge.py` (start_engine / get_yahoo with struct-array decomposition +
  timetable → time+matrix + nested Indicators + string→str; timerange_window gate oracle; plots/msg;
  stop_engine + diagnostics).
- [ ] #p1 Write `code/getYahoo/check_getYahoo.py` (query.json bootstrap; gate = fixed-window OHLCV for
  both tickers vs golden; SKIP on unreachable Yahoo, FAIL on aged-out window).
- [ ] #p1 Run the check on the R2026a + FSDA box with network access; confirm `PASS` with max abs diff
  `< 1e-9`, and that re-running is deterministic (golden bootstrapped run 1, matched run 2).
- [ ] #p2 Persist `reference/getYahoo_query.json`, `reference/getYahoo_window.csv`,
  `reference/getYahoo_check.csv` for the Layer-2 surfaces.
- [ ] #p3 Note the struct-array + timetable + timezone-datetime + nested-struct learnings for 014 / 015.

### Done

(move checked items here with a date — verification requires the MATLAB engine + Yahoo network access,
not available in the authoring environment)
