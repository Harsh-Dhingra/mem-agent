# Research foundations

Every non-trivial mechanism in mem-agent v0.3 is lifted from published work or
production systems. This file maps each component to its sources and says
which parameters came from where.

## Architecture

The core structure — a **predictor**, a **regime detector** that resets it, a
**corroborating pressure gauge** that gates actuation, and a
**disruption-aware action ranker** — is the separation every surveyed
production system maintains:

- Rzadca et al., *Autopilot: Workload Autoscaling at Google*, EuroSys 2020.
- Weiner et al., *TMO: Transparent Memory Offloading in Datacenters*, ASPLOS 2022.
- systemd-oomd / Meta oomd (production configs).

## Prediction (`Analysis/Holt.swift`, `Predictor.swift`)

- **Damped Holt ETS(A,Ad,N)** — Hyndman, Koehler, Ord & Snyder, *Forecasting
  with Exponential Smoothing: The State Space Approach*, Springer 2008; FPP3
  §8.7 for the h-dependent forecast variance. Parameters α=0.15, β=0.02,
  φ=0.97 chosen for 10s sampling / 15-min horizon. Damping exists because a
  memory freefall is almost never linear for 15 minutes — undamped trends
  systematically over-predict doom.
- **Robust scale + Huberized innovations** (1.4826 × EWMA|e|, clip at 3σ) —
  standard robust statistics; memory series are jump-contaminated (an app
  quits, 8 GB returns instantly).
- **Monte-Carlo first-passage distribution** (200 paths × 90 steps) — the
  actuation signal is `P(cross learned θ within 15 min)` plus p10/median
  ETAs, not a point estimate. FPP3 sanctions simulated sample paths for
  models without convenient closed-form intervals.
- **Why not ML**: the M4 competition (Makridakis et al., IJF 2018/2020) found
  pure ML/LSTM methods dominated by statistical ones across all horizons —
  and a memory daemon spending hundreds of MB to predict memory pressure
  refutes itself. ARIMA (unstable order selection on nonstationary traces)
  and seasonal Holt-Winters (no exploitable seasonality at this horizon)
  were also rejected deliberately.

## Regime detection (`Analysis/PageHinkley.swift`)

- **Page-Hinkley / CUSUM** — E. S. Page, *Continuous Inspection Schemes*,
  Biometrika 1954; Hinkley, Biometrika 1971; streaming form per Gama et al.,
  *A survey on concept drift adaptation*, ACM CSUR 2014. Two-sided on the
  derivative, asymmetric thresholds (drain side h=5σ fast, relief side h=7σ
  slow — the Senpai retreat-fast/advance-slow principle), k=0.6σ slack.
  On a trip: reseed the Holt trend from the last 6 derivatives and widen the
  variance ×4.
- **BOCPD** (Adams & MacKay 2007) was evaluated and rejected: ~8× the code
  and opaque priors for marginal gain on heavy-tailed memory derivatives;
  Page-Hinkley's two knobs map directly onto ARL₀ and detection delay.

## Learned thresholds (`Analysis/DecayedHistogram.swift`)

- **Autopilot's decayed histogram** (EuroSys 2020): exponential bucket
  spacing (ratio 1.05, per Kubernetes VPA — Autopilot's open-source
  descendant), sample weight 2^(τ/t½), **t½ = 48 h for memory** (Autopilot's
  own memory half-life), 5-minute window minima (Autopilot records memory
  extremes per window, not means, because memory overrun is fatal).
  θ_critical = p5 of lived minima, floored at 5% of RAM and capped at half
  the lived median (so a machine that has never felt pressure doesn't set θ
  at its own normal level).

## Pressure gauge (`Sensors/PressureGauge.swift`)

- **PSI semantics** — Johannes Weiner, Linux kernel v4.20; smoothing uses
  PSI's own decay constants (α_W = 1 − e^(−P/W) at 10/60s windows) and its
  zero-backfill across idle gaps (`calc_load_n`), so a laptop waking from
  sleep reports no phantom pressure.
- **The swap-in / swap-out discrimination** — TMO (ASPLOS 2022) and Senpai:
  swap-outs are healthy offloading (Senpai deliberately induces them);
  swap-ins — reading back what was just written — are the damage signal.
  Churn = min(in,out)/total is the classic thrash signature.
- **Paging duty cycle** — Denning, *Thrashing: Its Causes and Prevention*,
  AFIPS 1968 (the 50% rule; the L(x) < D collapse criterion), via per-event
  service costs (2 µs/decompress, 100 µs/swap-in, defaults pending local
  calibration).
- **Gate, not trigger** — a forecast without corroborating measured pain only
  warrants cheap reversible suggestions (thrash avg10 > 0.1 to escalate,
  > 0.3 to auto-execute), mirroring oomd's sustained-pressure thresholds.

## Leak detection (`Analysis/LeakDetector.swift`)

- **PrecogMF** — Jindal et al., *Memory Leak Detection Algorithms in the
  Cloud-based Infrastructure*, arXiv:2106.08938 (2021): per-app learned
  limits + a max-value filter took F1 from 0.568 (plain regression) to
  0.857. Our "footprint must exceed the app's own learned ceiling" is that
  filter.
- **Theil-Sen slope + Mann-Kendall gate** — Garg, van Moorsel, Vaidyanathan
  & Trivedi, *A Methodology for Detection and Estimation of Software Aging*,
  ISSRE 1998; the α=0.01 + Benjamini-Hochberg correction + 3-consecutive-
  windows requirement answers Matias et al. (ISSRE-W 2013), who showed MK
  alone false-alarms heavily on aging indicators.
- **Deceleration test** (second-half slope < 0.5 × first-half → cache
  warming, not a leak): the consensus asymptotic-vs-linear discriminator in
  production leak monitoring.
- **15-minute warmup gate** — Google's software-defined far memory
  (Lagar-Cavilla et al., ASPLOS 2019) never judges a job in its first S
  seconds; this killed our own observed cold-start false-positive class.
- **Per-app baselines** (48h-half-life histograms + weekly hourly peaks,
  frozen while an app is under suspicion, current hour excluded from the
  peak) — Autopilot again, plus the obvious guard that a leak must not train
  its own baseline.
- **Rejuvenation advisory** — Huang, Kintala, Kolettis & Fulton, *Software
  Rejuvenation*, FTCS-25 1995: restart is worthwhile when expected failure
  cost exceeds restart cost; v1 surfaces TTE-based restart recommendations
  (report-only) when exhaustion is < 4 h away.

## Action ranking (`Policy/UsageModel.swift`, Validator v0.3 rules)

- **SmartLMK** — Kim, Jeong, Kim & Maeng, ACM TECS 2016: value =
  ΔT × P(return), the reclaim decision as recovery-per-disruption; our
  `score = recovery × precision / (ΔT · P_return · dwell · severity)`.
- **PREPP** — Parate et al., UbiComp 2013: order-3 PPM over the app-switch
  sequence with per-order self-weighted accuracy (80.9% top-5 vs 48.8% MFU);
  their finding that location/time context adds only 0.5 points is why no
  context features exist here.
- **Firefox frecency** — Mozilla Places ranking docs: exponential-decay
  frequency×recency with the stored-date trick (compare stored timestamps,
  never re-sweep); session half-life shortened to 4 h for "will they switch
  back this session".
- **Iqbal & Horvitz** — *Disruption and Recovery of Computing Tasks*, CHI
  2007 (2,267 hours of field data): an app used 5–30 min and left minutes
  ago is the WORST suspend target (users return in 5–15 min); < 5-min
  dwells have ~10% no-return-in-2h. Hence the hard dwell rule in the
  validator — pure idle-time ranking gets this exactly backwards.
- **Android lmkd** — AOSP docs: pressure bands bound how deep reclaim may
  reach (30-min idle at WARN, 5-min at CRITICAL) and kills are debounced
  (one action → wait → re-measure).
- **Falcon** — Yan et al., MobiSys 2012: an explicit disruption budget
  (≤4 executed actions/hour, ≥30 min per target) so "is this daemon
  annoying" is a tunable number.
- **Acclaim** — Liang et al., USENIX ATC 2020: measure your own re-faults.
  A suspended app the user reactivates within 10 min, or a discarded tab
  they reopen, counts against that action type; > 25% re-fault rate
  auto-disables the type.
- **Marvin** — Lebeck, Krishnamurthy, Levy & Zhang, USENIX ATC 2020: the
  standing argument that reversible actions beat kills (2× app concurrency
  without killing anything).

## Chrome tab policy (`Chrome.swift`, extension)

- **Chromium TabRanker / ChromiumOS tab-discarding design doc**: two-stage
  policy — hard vetoes (active, pinned, audible, recent, focused window)
  that never enter the score, then a cheap ranker; staleness dominates,
  reactivation history protects.
- **Chang et al., *When the Tab Comes Due*, CHI 2021**: a tab's value is
  often its presence (an externalized to-do), so discard — never close,
  never reorder — and never touch the focused window (the user's visual
  working set). Bottom-K discards sized to the recovery demand instead of
  sweeping every eligible tab.

## Self-evaluation (`Analysis/Backtest.swift`)

- **Counterfactual evaluation** — Google far-memory (ASPLOS 2019): judge a
  policy by what it *would* have done on recorded history. `memagent
  backtest` replays the daemon's own SQLite trace through the new and legacy
  predictors and scores both against actual kernel pressure transitions.
