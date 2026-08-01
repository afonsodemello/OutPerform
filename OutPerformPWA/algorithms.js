/* OutPerform — scoring engine, ported 1:1 from the iOS app's Swift calculators
   so the PWA produces the same numbers as the native app. */

const OP = (() => {
  // ---- stats ----
  const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);
  const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
  const std = (xs) => {
    if (xs.length < 2) return 0;
    const m = mean(xs);
    return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1));
  };
  const z = (v, m, s) => (s > 0 ? (v - m) / s : 0);
  function percentile(xs, p) {
    if (!xs.length) return 0;
    const s = [...xs].sort((a, b) => a - b);
    const idx = clamp(p, 0, 1) * (s.length - 1);
    const lo = Math.floor(idx), hi = Math.ceil(idx);
    if (lo === hi) return s[lo];
    return s[lo] + (s[hi] - s[lo]) * (idx - lo);
  }

  // ---- HR max / strain (StrainCalculator) ----
  const gellishHRMax = (age) => 192 - 0.007 * age * age;
  function personalisedHRMax(age, allHeartRates, method = "max") {
    const gellish = gellishHRMax(age);
    if (!allHeartRates || allHeartRates.length <= 50) return gellish;
    const learned = percentile(allHeartRates, 0.95);
    if (method === "gellish") return gellish;
    if (method === "learned") return learned;
    return Math.max(gellish, learned);
  }
  function zoneWeight(hr, hrMax) {
    if (hrMax <= 0) return 0;
    const p = hr / hrMax;
    return p < 0.5 ? 0 : p < 0.6 ? 1 : p < 0.7 ? 2 : p < 0.8 ? 3 : p < 0.9 ? 4 : 5;
  }
  // TRIMP from {t:Date|ms, v} samples — binned into 1-minute buckets (avg HR/min).
  function trimpFromSamples(samples, hrMax) {
    if (!samples || !samples.length || hrMax <= 0) return 0;
    const buckets = {};
    for (const s of samples) {
      const ms = s.t instanceof Date ? s.t.getTime() : s.t;
      const minute = Math.floor(ms / 60000);
      (buckets[minute] = buckets[minute] || []).push(s.v);
    }
    let total = 0;
    for (const k in buckets) total += zoneWeight(mean(buckets[k]), hrMax);
    return total;
  }
  function strainFromTRIMP(trimp, scale = 150, coef = 4.8) {
    if (trimp <= 0) return 0;
    return clamp(coef * Math.log(1 + trimp / scale), 0, 21);
  }

  // ---- recovery (RecoveryCalculator) ----
  const DEFAULT_RECOVERY_WEIGHTS = { hrv: 0.40, rhr: 0.25, resp: 0.10, sleep: 0.25 };
  function scoreFromZ(zv) { return clamp(50 + 22 * clamp(zv, -2, 2), 0, 100); }

  // input: { rmssd, restingHR, respiratoryRate, sleepPerformance, skinTempC, spo2Avg,
  //          rmssdMean3, rmssdStd7, rhrMean7, rhrStd14, respMean14, respStd14, skinTempMean14 }
  function recovery(i, weights) {
    const w = weights || DEFAULT_RECOVERY_WEIGHTS;
    let weighted = 0, totalW = 0;

    if (i.rmssd != null && i.rmssdMean3 != null && i.rmssdStd7 > 0) {
      const sc = scoreFromZ(z(i.rmssd, i.rmssdMean3, i.rmssdStd7));
      weighted += w.hrv * sc; totalW += w.hrv;
    }
    if (i.restingHR != null && i.rhrMean7 != null && i.rhrStd14 > 0) {
      const sc = scoreFromZ((i.rhrMean7 - i.restingHR) / i.rhrStd14);
      weighted += w.rhr * sc; totalW += w.rhr;
    }
    if (i.respiratoryRate != null && i.respMean14 != null && i.respStd14 > 0) {
      const sc = scoreFromZ(-((i.respiratoryRate - i.respMean14) / i.respStd14));
      weighted += w.resp * sc; totalW += w.resp;
    }
    if (i.sleepPerformance != null) {
      const sc = clamp(i.sleepPerformance, 0, 100);
      weighted += w.sleep * sc; totalW += w.sleep;
    }
    if (totalW === 0) return null;                 // no baseline yet → calibrating
    let base = weighted / totalW;

    // Skin-temperature penalty.
    if (i.skinTempC != null && i.skinTempMean14 != null) {
      const dev = i.skinTempC - i.skinTempMean14;
      if (dev > 0.5) base -= clamp((dev - 0.5) * 10, 0, 10);
      else if (dev < -0.3) base += 1;
    }
    // SpO2 penalty.
    if (i.spo2Avg != null) {
      base += i.spo2Avg >= 96 ? 0 : i.spo2Avg >= 94 ? -5 : i.spo2Avg >= 90 ? -15 : -25;
    }
    return Math.round(clamp(base, 0, 100));
  }

  // ---- sleep performance (SleepCalculator) ----
  const DEFAULT_SLEEP_WEIGHTS = { efficiency: 0.30, restorative: 0.30, fulfillment: 0.25, consistency: 0.15 };
  // m: { efficiencyPct, restorativePct, totalSleepMin }
  function sleepPerformance(m, sleepNeedMin, bedtimeStdHours, weights) {
    if (!m || !m.totalSleepMin) return null;
    const w = weights || DEFAULT_SLEEP_WEIGHTS;
    const efficiency = clamp((m.efficiencyPct ?? 90) / 100, 0, 1);
    const restorative = clamp((m.restorativePct ?? 0) / 40, 0, 1);
    const fulfillment = sleepNeedMin > 0 ? clamp(m.totalSleepMin / sleepNeedMin, 0, 1) : 0;
    const consistency = clamp(1 - ((bedtimeStdHours ?? 0) / 2), 0, 1);
    const score = clamp(
      efficiency * w.efficiency + restorative * w.restorative +
      fulfillment * w.fulfillment + consistency * w.consistency, 0, 1) * 100;
    return Math.round(score);
  }

  // ---- sleep need (SleepNeedCalculator) ----
  function sleepNeedMinutes(baselineMin, yesterdayStrain, carriedDebtMin = 0, napMin = 0) {
    const strainExtra = (1.7 / (1 + Math.exp((17 - yesterdayStrain) / 3.5))) * 60;
    const debt = Math.min(Math.max(carriedDebtMin, 0) * 0.5, 90);
    return baselineMin + strainExtra + debt - napMin;
  }

  // ---- stress (StressCalculator) — vs 14-day baseline ----
  function stress(currentHRV, hrvMean14, hrvStd14, currentHR, hrMean14, hrStd14) {
    if (currentHRV == null || currentHR == null || !(hrvStd14 > 0) || !(hrStd14 > 0)) return null;
    const hrvZ = z(currentHRV, hrvMean14, hrvStd14);
    const hrZ = z(currentHR, hrMean14, hrStd14);
    const raw = -hrvZ * 0.65 + hrZ * 0.35;
    return Math.round(clamp(50 + raw * 15, 0, 100));
  }

  // ---- ACWR / monotony / sleep debt ----
  const ewma = (prev, val, lambda) => val * lambda + prev * (1 - lambda);
  const LAMBDA_ACUTE = 2 / (7 + 1), LAMBDA_CHRONIC = 2 / (28 + 1);
  function updateACWR(prev, strain) {
    const a = ewma(prev ? prev.a : strain, strain, LAMBDA_ACUTE);
    const c = ewma(prev ? prev.c : strain, strain, LAMBDA_CHRONIC);
    return { a, c, ratio: c > 0 ? a / c : 0 };
  }
  function monotony(last7) {
    if (last7.length < 7) return null;
    const m = mean(last7), s = std(last7);
    return s > 0 ? m / s : null;
  }
  function updatedDebt(prevDebt, need, actual) {
    if (!(actual > 0)) return prevDebt;               // missing night → don't accrue
    return clamp(prevDebt + (need - actual), 0, 180); // cap at 3h, decays as you catch up
  }

  // ---- readiness (ReadinessCalculator) ----
  function acwrFactor(ratio) {
    if (!(ratio > 0)) return 100;
    if (ratio >= 0.8 && ratio <= 1.3) return 100;
    const d = ratio < 0.8 ? 0.8 - ratio : ratio - 1.3;
    return clamp(100 - d * 30, 0, 100);
  }
  function readiness(rec, sleepPerf, acwr) {
    if (rec == null) return null;
    const sp = sleepPerf != null ? sleepPerf : rec;
    return Math.round(clamp(rec * 0.60 + sp * 0.25 + acwrFactor(acwr ?? 0) * 0.15, 0, 100));
  }

  // ---- cognitive readiness (Three-Process Model) ----
  const CR = {
    peakHour: 16.5, refMid: 3.5, tauS: 12, tauW: 0.45,
    circadian(t, mid) {
      const shift = (mid ?? CR.refMid) - CR.refMid;
      const peak = CR.peakHour + shift;
      return Math.cos((2 * Math.PI * (t - peak)) / 24) + 0.4 * Math.cos((2 * Math.PI * 2 * (t - (peak - 3))) / 24);
    },
    homeostatic(hAwake, priorSleepMin, debtMin) {
      const h = Math.max(0, hAwake);
      const nf = clamp(priorSleepMin / 480, 0, 1);
      const dp = clamp(debtMin / 480, 0, 0.6);
      const start = clamp(0.55 + 0.45 * nf - dp, 0.1, 1);
      return 0.15 + (start - 0.15) * Math.exp(-h / CR.tauS);
    },
    inertia(hAwake) { return 1 - 0.45 * Math.exp(-Math.max(0, hAwake) / CR.tauW); },
    readiness(hourOfDay, inp) {
      const hAwake = hourOfDay - inp.wakeHour;
      const s = CR.homeostatic(hAwake, inp.priorSleepMin, inp.sleepDebtMin || 0);
      const c = CR.circadian(hourOfDay, inp.midpoint);
      const w = CR.inertia(hAwake);
      let score = 100 * (0.62 * s + 0.38 * ((c + 1.4) / 2.8)) * w;
      if (inp.hrvZ != null) score += 6 * clamp(inp.hrvZ, -2, 2);
      if (inp.stress != null) score -= 0.2 * (inp.stress - 50);
      if (inp.dayStrain != null && inp.dayStrain > 12) score -= Math.min(8, (inp.dayStrain - 12) * 1.2) * clamp(hAwake / 10, 0, 1);
      return clamp(score, 0, 100);
    },
    curve(inp, fromH = null, toH = null, step = 0.25) {
      const from = fromH ?? inp.wakeHour, to = toH ?? inp.wakeHour + 17, out = [];
      for (let t = from; t <= to; t += step) out.push({ h: t, score: CR.readiness(t, inp) });
      return out;
    },
    peakWindows(curve, minHours = 0.75) {
      const max = Math.max(...curve.map((p) => p.score), 0);
      if (max <= 0) return [];
      const thr = Math.max(65, max * 0.9);
      const wins = []; let start = null, peak = 0, last = null;
      for (const p of curve) {
        if (p.score >= thr) { if (start == null) { start = p.h; peak = p.score; } peak = Math.max(peak, p.score); last = p.h; }
        else if (start != null) { if (last - start >= minHours) wins.push({ start, end: last, peak }); start = null; peak = 0; }
      }
      if (start != null && last - start >= minHours) wins.push({ start, end: last, peak });
      return wins;
    },
  };

  // ---- zones ----
  const recoveryZone = (s) => (s < 34 ? { label: "Rest", color: "red" } : s < 67 ? { label: "Moderate", color: "yellow" } : { label: "Primed", color: "green" });
  const strainZone = (s) => (s < 10 ? { label: "Light", color: "blue" } : s < 14 ? { label: "Moderate", color: "cyan" } : s < 18 ? { label: "High", color: "yellow" } : { label: "All-out", color: "red" });
  const focusZone = (s) => (s < 40 ? { label: "Low", color: "red" } : s < 65 ? { label: "Moderate", color: "yellow" } : s < 82 ? { label: "High", color: "blue" } : { label: "Peak", color: "purple" });

  return {
    clamp, mean, std, z, percentile,
    gellishHRMax, personalisedHRMax, zoneWeight, trimpFromSamples, strainFromTRIMP,
    recovery, sleepPerformance, sleepNeedMinutes, stress, readiness, acwrFactor,
    updateACWR, monotony, updatedDebt,
    CR, recoveryZone, strainZone, focusZone,
    DEFAULT_RECOVERY_WEIGHTS, DEFAULT_SLEEP_WEIGHTS,
  };
})();
