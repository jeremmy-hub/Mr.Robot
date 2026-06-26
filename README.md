# Mustafa_FX Retest Strategy (MQL5 Expert Advisor)

A bias-aware MetaTrader 5 Expert Advisor that trades **liquidity-based SMC setups** through two
selectable signal engines:

- **Continuation** — bias-aligned breakout → retest entries (the original engine).
- **CRT** — parallel **Candle Range Theory** detection on the 4H and 1H, with entries timed on the M5.

Both engines feed a single, shared execution and risk-management pipeline (two-leg sizing,
break-even-with-lock, ATR trailing, and multi-trigger order invalidation).

---

## ⚠️ Risk & status disclaimer

This is trading software for the leveraged FX/CFD/crypto markets, where **you can lose money
rapidly**. It is provided as-is, for research and education.

- It has **not been independently compiled, audited, or backtested** by anyone but the author.
  Compile it in MetaEditor and run a full Strategy Tester pass (ideally walk-forward /
  out-of-sample) **before** any live use.
- Nothing here is financial advice or a recommendation to trade.
- Test on a **demo account** first, on the exact symbol and broker you intend to use.

---

## Requirements

- MetaTrader 5 (recent build).
- A broker symbol with valid tick size / tick value and hedging mode (for multi-leg orders).
- Sufficient chart history loaded for the 200-period EMA and the 4H/1H candles used by the CRT engine.

## Installation

1. Copy `Mustafa_FX_retest_strategy.mq5` into `MQL5/Experts/` in your MT5 data folder.
2. Open it in MetaEditor and **Compile** (F7). Resolve any broker-specific warnings.
3. Attach it to a chart and allow **algo trading**.

### Which chart to attach to

| Engine you run            | Attach EA to |
|---------------------------|--------------|
| `ENGINE_CRT` (default)    | **M5 chart** |
| `ENGINE_BOTH`             | **M5 chart** |
| `ENGINE_CONTINUATION`     | Your chosen trading timeframe (e.g. M15) |

The CRT engine reads the 4H and 1H internally; you do **not** attach it to those charts.

---

## How it works

### Continuation engine
Trades in the direction of the 200-EMA master bias when a swing breaks with momentum, then waits
for a retest. The entry anchor is selectable via `EntryMode`:

- `ENTRY_LEGACY_EMA` — limit at the 21 EMA ± a depth offset.
- `ENTRY_FVG_FILL` — limit at the 50% of the breakout fair-value gap (default).
- `ENTRY_OTE_BAND` — limit inside the OTE retracement band.

### CRT engine (Candle Range Theory)
Two independent state machines, one per timeframe, run in parallel — **either** can produce a
trade:

1. **C1 (range)** — the reference candle defines a high/low range; its midpoint is the 50% equilibrium.
2. **C2 (manipulation)** — the next candle sweeps C1's high or low and **closes back inside** the range.
   With `CRT_PremiumDiscount` on, C2 must close in the discount half (for longs) or premium half (for shorts).
3. **M5 trigger** — once armed, the EA waits for an M5 displacement fair-value gap in the CRT's
   direction and places a limit at that gap.
4. **Targets** — SL beyond the C2 sweep wick, **TP1 at the 50% equilibrium**, **TP2 at the opposite
   range extreme**.

Each armed CRT prints to the journal (`CRT armed (PERIOD_H4) …`) so you can verify detection.

### Shared execution & risk (both engines)
- **Two-leg sizing** — total risk split into two equal, volume-step-normalized legs (TP1 / TP2).
- **Break-even with lock** — at `BE_Activation_Percent` of the TP1 distance, the stop moves to entry
  **plus a positive cushion** (`BE_Lock_R`), floored above spread + commission so a "break-even" exit
  is never a net loss.
- **ATR trailing** — after activation, the stop trails by `Trail_Atr_Mult × ATR` and only ever tightens.
- **Invalidation** — pending orders are cancelled by: code-level bar-age expiry (`MaxHuntBars`,
  enforced regardless of broker expiry support), structural breach (close beyond the level the setup
  was built on), opposing displacement, and — continuation engine only — master-bias flip.

---

## Key inputs

### Engine & CRT
| Input | Default | Notes |
|---|---|---|
| `SignalEngine` | `ENGINE_CRT` | `CONTINUATION` / `CRT` / `BOTH` |
| `CRT_TF_A` / `CRT_TF_B` | `PERIOD_H4` / `PERIOD_H1` | The two CRT timeframes |
| `CRT_PremiumDiscount` | `true` | Require C2 close in the correct half |
| `CRT_BiasLockToTF_A` | `false` | `false` = trade both directions (pure CRT) |
| `CRT_UseKillzone` | `true` | Gates **entries** (not arming) to the windows below |
| `CRT_KZ1_Start/End` | `7 / 10` | Killzone 1 (London) — **SERVER time** |
| `CRT_KZ2_Start/End` | `12 / 15` | Killzone 2 (NY AM) — **SERVER time** |
| `CRT_SweepBufferPoints` | `0` | Extra SL distance beyond the sweep wick |

### Risk & stops
| Input | Default | Notes |
|---|---|---|
| `RiskPercent` | `1.0` | Total risk per setup, % of balance |
| `TP1_RewardRatio` / `TP2_RewardRatio` | `1.0 / 1.5` | R-multiples (continuation engine) |
| `BE_Activation_Percent` | `50.0` | % of TP1 distance that arms break-even |
| `BE_Lock_R` | `0.15` | Profit locked at break-even, in R |
| `BE_Cost_Buffer_Points` | `0` | Extra cushion for commission |
| `UseTrailing` | `true` | ATR trailing after activation |
| `Trail_Atr_Mult` | `1.5` | Trailing distance in ATR |
| `MaxSetupsPerTimeframe` | `1` | Concurrent setups (shared across engines) |

### Invalidation
| Input | Default |
|---|---|
| `UseStructuralInvalidation` | `true` |
| `CancelOnOpposingDisplacement` | `true` |
| `CancelOnBiasFlip` | `true` (continuation only) |
| `MaxHuntBars` | `40` |

### Continuation engine
| Input | Default |
|---|---|
| `EntryMode` | `ENTRY_FVG_FILL` |
| `RequireDisplacement` | `true` |
| `DisplacementBodyAtr` | `1.0` |
| `OteLevel` | `0.705` |
| `BiasEmaLen` / `FastEmaLen` / `SlowEmaLen` / `PullEmaLen` | `200 / 34 / 144 / 21` |
| `BreakLookback` | `20` |
| `MinBreakBodyAtr` | `0.20` |
| `SlBufferAtr` | `0.30` |

---

## ⏰ Killzone calibration (read this)

The killzone hours are in **broker server time, not your local time**. MT5 servers are commonly
GMT+2 / GMT+3, which is **not** EAT/EST. If the windows are wrong, **CRT entries will never fire**
even though setups arm.

On init the EA prints the current server hour — use it to align `CRT_KZ1`/`CRT_KZ2` to roughly the
London (≈07:00–10:00 London) and New York AM (≈08:00–11:00 New York) windows in your server's offset.
To disable timing entirely, set `CRT_UseKillzone = false`.

---

## Troubleshooting: "a CRT was missed"

Check the journal for a `CRT armed …` line for that candle:

- **It armed, but no trade** → the killzone (entry time outside the windows) or the M5 trigger
  (no displacement FVG in the zone, or price not in the correct half). Verify server-time killzone
  hours first.
- **It did not arm** → either `CRT_PremiumDiscount` rejected it (C2 closed in the wrong half), or the
  sweep candle was **not the candle immediately after** the range candle. The detector currently treats
  C1 = the candle before C2 (strict adjacency); non-adjacent manipulations are not yet detected.

---

## Version history

| Version | Summary |
|---|---|
| **v4.00** | Original bias-aligned EMA breakout-retest. |
| **v4.01** | Hardening: ceiling setup count, price/volume normalization, order-side validation, partial-fill rollback, data-copy guards, expiration fallback, bias-flip cancel. |
| **v4.02** | SMC structure module: displacement filter + selectable FVG-fill / OTE entry anchors (legacy preserved). |
| **v4.03** | Stop rework: break-even locks a positive cushion (cost-floored), plus optional ATR trailing for the runner. |
| **v4.04** | Invalidation rework: code-level bar-age expiry (broker-independent), structural invalidation, opposing-displacement cancel. |
| **v4.05** | CRT signal engine: parallel 4H + 1H Candle Range Theory with M5 entries, premium/discount filter, killzone gate, `SignalEngine` selector. |
| **v4.06** | CRT killzone fix: all valid CRTs now arm (and print); killzone gates only entries, not the C1 range-candle open time (which had silently dropped most 4H CRTs). |

---

## License

all rights reserved by the author @jeyMustafa_fx.
