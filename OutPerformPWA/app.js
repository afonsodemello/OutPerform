/* OutPerform PWA — app shell logic */
(() => {
  "use strict";

  // ---------- Service worker ----------
  if ("serviceWorker" in navigator) {
    // When a new SW takes control, reload once so the latest code is used.
    let reloaded = false;
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (reloaded) return; reloaded = true; location.reload();
    });
    window.addEventListener("load", () => {
      navigator.serviceWorker.register("sw.js").then((reg) => reg.update()).catch(() => {});
    });
  }

  // ---------- Config (user-editable: age, sex, formula weights) ----------
  // Kept separate from synced data so it survives sync/clear.
  const CFG_KEY = "op_pwa_cfg_v1";
  function loadCfg() {
    const def = { age: 25, sex: "other", recW: { ...OP.DEFAULT_RECOVERY_WEIGHTS } };
    try { const r = localStorage.getItem(CFG_KEY); if (r) { const o = JSON.parse(r); return { ...def, ...o, recW: { ...def.recW, ...(o.recW || {}) } }; } } catch (e) {}
    return def;
  }
  let CFG = loadCfg();
  function saveCfg() { localStorage.setItem(CFG_KEY, JSON.stringify(CFG)); }

  // ---------- Data layer ----------
  const KEY = "op_pwa_data_v1";
  // No sample/fake data — empty until a real source syncs. `rawDays` holds the
  // aligned per-day data from Google Health; everything else is derived from it.
  function emptyData() { return { profile: { age: 25 }, napMin: 0 }; }
  function load() {
    try { const raw = localStorage.getItem(KEY); if (raw) return JSON.parse(raw); } catch (e) {}
    return emptyData();
  }
  function save(d) { localStorage.setItem(KEY, JSON.stringify(d)); }
  let D = load();
  function hasData() { return !!(D.rawDays && D.rawDays.length); }

  // Chronological engine pass — recomputes every day's scores from the aligned
  // raw data (mirrors the iOS ScoreEngine), carrying rolling baselines, ACWR and
  // sleep debt forward. Re-run on every render so weight changes apply live.
  function buildHistory(days, recW) {
    const tail = (a, n) => a.slice(Math.max(0, a.length - n));
    const hist = [];
    const pHrv = [], pRhr = [], pResp = [], pTemp = [], bedtimes = [], recentTotals = [], lowStrainTotals = [];
    let acwr = null, carriedDebt = 0, prevDayStrain = 0;
    for (const d of days) {
      const rmssdMean3 = pHrv.length ? OP.mean(tail(pHrv, 3)) : null;
      const rmssdStd7 = pHrv.length >= 2 ? OP.std(tail(pHrv, 7)) : null;
      const rhrMean7 = pRhr.length ? OP.mean(tail(pRhr, 7)) : null;
      const rhrStd14 = pRhr.length >= 2 ? OP.std(tail(pRhr, 14)) : null;
      const respMean14 = pResp.length ? OP.mean(tail(pResp, 14)) : null;
      const respStd14 = pResp.length >= 2 ? OP.std(tail(pResp, 14)) : null;
      const skinTempMean14 = pTemp.length ? OP.mean(tail(pTemp, 14)) : null;
      const hrvMean14 = pHrv.length ? OP.mean(tail(pHrv, 14)) : null;
      const hrvStd14 = pHrv.length >= 2 ? OP.std(tail(pHrv, 14)) : null;
      const rhrMean14 = pRhr.length ? OP.mean(tail(pRhr, 14)) : null;
      const rhrStd14b = pRhr.length >= 2 ? OP.std(tail(pRhr, 14)) : null;

      const baseMin = lowStrainTotals.length >= 3 ? OP.mean(tail(lowStrainTotals, 30))
        : (recentTotals.length ? OP.mean(tail(recentTotals, 30)) : 455);
      const pastNeed = OP.sleepNeedMinutes(baseMin, prevDayStrain, carriedDebt);
      let sleepPerf = null;
      if (d.sleep && d.sleep.totalSleepMin > 0) {
        const bedStd = bedtimes.length >= 2 ? OP.std(tail(bedtimes, 14)) : 0;
        sleepPerf = OP.sleepPerformance(d.sleep, pastNeed, bedStd);
        carriedDebt = OP.updatedDebt(carriedDebt, pastNeed, d.sleep.totalSleepMin);
      }
      const rec = OP.recovery({
        rmssd: d.hrv, restingHR: d.restingHR, respiratoryRate: d.respiratoryRate, sleepPerformance: sleepPerf,
        skinTempC: d.skinTempC, spo2Avg: d.spo2Avg, rmssdMean3, rmssdStd7, rhrMean7, rhrStd14, respMean14, respStd14, skinTempMean14,
      }, recW);
      const str = OP.stress(d.hrv, hrvMean14, hrvStd14, d.restingHR, rhrMean14, rhrStd14b);
      if (d.dayStrain != null) acwr = OP.updateACWR(acwr, d.dayStrain);
      const acwrRatio = acwr ? acwr.ratio : null;
      const read = OP.readiness(rec, sleepPerf, acwrRatio);
      const tonightNeed = OP.sleepNeedMinutes(baseMin, d.dayStrain ?? 0, carriedDebt);

      const entry = Object.assign({}, d, d.sleep || {}, {
        recovery: rec, sleepPerformance: sleepPerf, stress: str, readiness: read,
        sleepNeedMin: tonightNeed, sleepDebtMin: carriedDebt, acwr: acwrRatio,
        hrvMean14, hrvStd14, rhrMean14, rhrStd14b, rmssdMean3, rmssdStd7, rhrMean7, rhrStd14, respMean14, respStd14, skinTempMean14,
        sleepOnset: d.sleepStart, sleepWake: d.sleepEnd,
      });
      hist.push(entry);

      if (d.hrv != null) pHrv.push(d.hrv);
      if (d.restingHR != null) pRhr.push(d.restingHR);
      if (d.respiratoryRate != null) pResp.push(d.respiratoryRate);
      if (d.skinTempC != null) pTemp.push(d.skinTempC);
      if (d.sleep && d.sleep.totalSleepMin > 0) {
        const o = new Date(d.sleepStart); let h = o.getHours() + o.getMinutes() / 60; if (h < 12) h += 24;
        bedtimes.push(h); recentTotals.push(d.sleep.totalSleepMin);
        if ((d.dayStrain ?? 99) < 8) lowStrainTotals.push(d.sleep.totalSleepMin);
      }
      prevDayStrain = d.dayStrain ?? prevDayStrain;
    }
    const last7 = hist.slice(-7).map((h) => h.dayStrain).filter((x) => x != null);
    const today = hist[hist.length - 1] || {};
    return { history: hist, today, acwrRatio: today.acwr ?? null, monotony: OP.monotony(last7) };
  }

  function seriesFromHistory(hist) {
    const ms = (k) => new Date(k + "T12:00:00").getTime();
    const ser = (key) => hist.map((h) => ({ t: ms(h.date), v: h[key] })).filter((p) => p.v != null);
    return {
      readiness: ser("readiness"), recovery: ser("recovery"), strain: ser("dayStrain"),
      sleepPerformance: ser("sleepPerformance"), stress: ser("stress"),
      hrv: ser("hrv"), restingHR: ser("restingHR"), respiratoryRate: ser("respiratoryRate"),
      skinTempC: ser("skinTempC"), spo2Avg: ser("spo2Avg"), totalSleep: ser("totalSleepMin"),
    };
  }

  // ---------- Derived scores ----------
  function compute() {
    if (!hasData()) return { rec: null, sleepPerf: null, str: null, read: null, need: null, history: [], focusInp: { wakeHour: 7, priorSleepMin: 0, sleepDebtMin: 0 } };
    const built = buildHistory(D.rawDays, CFG.recW);
    Object.assign(D, built.today);     // merge today's computed + raw values for the views
    D.acwr = built.acwrRatio; D.monotony = built.monotony; D.history = built.history;
    D.series = seriesFromHistory(built.history);
    D.wakeHour = D.sleepWake ? new Date(D.sleepWake).getHours() + new Date(D.sleepWake).getMinutes() / 60 : 7;
    D.sleepMidpoint = (D.sleepOnset && D.sleepWake) ? new Date((D.sleepOnset + D.sleepWake) / 2).getHours() : 3;
    const hrvZ = (D.hrvStd14 > 0) ? OP.z(D.hrv, D.hrvMean14, D.hrvStd14) : null;
    const focusInp = {
      wakeHour: D.wakeHour || 7, priorSleepMin: D.totalSleepMin || 0, sleepDebtMin: D.sleepDebtMin || 0,
      midpoint: D.sleepMidpoint, hrvZ, stress: D.stress, dayStrain: D.dayStrain,
    };
    return { rec: D.recovery, sleepPerf: D.sleepPerformance, str: D.stress, read: D.readiness, need: D.sleepNeedMin, history: built.history, focusInp };
  }

  // ---------- Ring rendering ----------
  function ring(value, progress, color, size, stroke, valText, cap) {
    const r = (size - stroke) / 2, c = 2 * Math.PI * r;
    const off = c * (1 - OP.clamp(progress, 0, 1));
    const vsize = size > 130 ? "2.4rem" : size > 90 ? "1.5rem" : "1.1rem";
    return `<span class="ring" style="width:${size}px;height:${size}px">
      <svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
        <circle class="track" cx="${size/2}" cy="${size/2}" r="${r}" stroke-width="${stroke}"></circle>
        <circle class="bar" cx="${size/2}" cy="${size/2}" r="${r}" stroke-width="${stroke}"
          stroke="var(--${color})" stroke-dasharray="${c.toFixed(1)}"
          stroke-dashoffset="${c.toFixed(1)}" data-off="${off.toFixed(1)}"></circle>
      </svg>
      <span class="lab"><span class="val" style="font-size:${vsize};color:var(--${color})">${valText}</span>${cap ? `<span class="cap">${cap}</span>` : ""}</span>
    </span>`;
  }
  function animateRings() {
    document.querySelectorAll(".ring .bar").forEach((b) => {
      requestAnimationFrame(() => requestAnimationFrame(() => { b.style.strokeDashoffset = b.dataset.off; }));
    });
  }

  const fmtMin = (m) => m == null ? "—" : `${Math.floor(m / 60)}h ${Math.round(m % 60)}m`;
  const fmtHour = (h) => { const hh = Math.floor(h) % 24, mm = Math.round((h - Math.floor(h)) * 60); const ap = hh < 12 ? "AM" : "PM"; const h12 = ((hh + 11) % 12) + 1; return `${h12}:${String(mm).padStart(2,"0")} ${ap}`; };

  // Empty state — shown whenever there's no real data (no fake data is ever used).
  function emptyState(msg) {
    return `<div class="card center" style="padding:34px 18px">
      <div style="font-size:2rem">📡</div>
      <h3 style="margin:10px 0 6px">No data yet</h3>
      <div class="guidance" style="margin:0 0 14px">${msg}</div>
      ${GH.isSignedIn()
        ? `<button class="btn" data-action="sync" ${syncing ? "disabled" : ""}>${syncing ? "Syncing…" : "Sync now"}</button>`
        : `<button class="btn" data-action="goData">Connect a data source</button>`}
    </div>`;
  }

  // ---------- Views ----------
  function viewToday(s) {
    if (!hasData()) {
      return `${installBanner()}${ghBanner()}${emptyState("Connect a data source and sync to see your scores. OutPerform never shows sample data, so your numbers always reflect real readings. On this web app, connect Google Health in the Data tab.")}`;
    }
    const recZ = D.hrv != null ? OP.recoveryZone(s.rec ?? 0) : null;
    const strZ = OP.strainZone(D.dayStrain || 0);
    const guidance = s.rec == null ? "Add your data in the Data tab to see your scores."
      : s.rec >= 67 ? "You're primed — your body can handle a hard session today."
      : s.rec >= 34 ? "Moderately recovered. Train smart and listen to your body."
      : "Low recovery — prioritise rest, light movement and good sleep tonight.";
    return `
      ${installBanner()}
      ${ghBanner()}
      <div class="card center tappable" data-detail="readiness">
        <div class="bigring">${ring(s.read, (s.read||0)/100, "purple", 180, 14, s.read ?? "—", "Readiness")}</div>
        ${s.rec!=null?`<span class="pill ${recZ.color}">${recZ.label}</span>`:""}
        <div class="guidance">${guidance} · tap for details</div>
      </div>
      <div class="tiles">
        <div class="tile tappable" data-detail="recovery">${ring(s.rec, (s.rec||0)/100, recZ?recZ.color:"green", 84, 7, s.rec ?? "—")}<div class="l">Recovery</div></div>
        <div class="tile tappable" data-detail="strain">${ring(D.dayStrain, (D.dayStrain||0)/21, strZ.color, 84, 7, D.dayStrain!=null?D.dayStrain.toFixed(1):"—")}<div class="l">Strain</div></div>
        <div class="tile tappable" data-detail="sleepPerformance">${ring(s.sleepPerf, (s.sleepPerf||0)/100, "purple", 84, 7, s.sleepPerf ?? "—")}<div class="l">Sleep</div></div>
      </div>`;
  }

  function viewFocus(s) {
    if (D.totalSleepMin == null) return emptyState("Your focus curve is built from last night's sleep and your wake time. Connect a data source and sync first.");
    const nowH = new Date().getHours() + new Date().getMinutes() / 60;
    const curve = OP.CR.curve(s.focusInp);
    const nowScore = Math.round(OP.CR.readiness(nowH, s.focusInp));
    const fz = OP.focusZone(nowScore);
    const wins = OP.CR.peakWindows(curve).filter((w) => w.end >= nowH - 0.1);
    const minH = curve[0].h, maxH = curve[curve.length - 1].h, W = 320, H = 150;
    const X = (h) => ((h - minH) / (maxH - minH)) * W;
    const Y = (sc) => H - (sc / 100) * H;
    let path = curve.map((p, i) => `${i ? "L" : "M"} ${X(p.h).toFixed(1)} ${Y(p.score).toFixed(1)}`).join(" ");
    const area = `${path} L ${W} ${H} L 0 ${H} Z`;
    const bands = wins.map((w) => `<rect x="${X(w.start).toFixed(1)}" y="0" width="${(X(w.end)-X(w.start)).toFixed(1)}" height="${H}" fill="#8d73f2" fill-opacity="0.12"></rect>`).join("");
    const nowLine = (nowH>=minH&&nowH<=maxH) ? `<line x1="${X(nowH).toFixed(1)}" y1="0" x2="${X(nowH).toFixed(1)}" y2="${H}" stroke="rgba(255,255,255,.35)" stroke-width="1" stroke-dasharray="4 4"></line>` : "";
    const winList = wins.length
      ? wins.map((w) => `<div style="display:flex;justify-content:space-between;margin:6px 0"><span>${fmtHour(w.start)} – ${fmtHour(w.end)}</span><span class="pill purple">peak ${Math.round(w.peak)}</span></div>`).join("")
      : `<div class="muted">No more peak windows today — protect tomorrow's with good sleep.</div>`;
    return `
      <div class="card center tappable" data-detail="focus">
        <div class="bigring">${ring(nowScore, nowScore/100, fz.color, 180, 14, nowScore, "Focus now")}</div>
        <span class="pill ${fz.color}">${fz.label}</span>
      </div>
      <div class="card">
        <h3>Today's focus curve</h3>
        <svg viewBox="0 0 ${W} ${H}" style="width:100%;height:150px">
          <defs><linearGradient id="cf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8d73f2" stop-opacity="0.4"/><stop offset="1" stop-color="#8d73f2" stop-opacity="0"/></linearGradient></defs>
          ${bands}
          <line x1="0" y1="${Y(50)}" x2="${W}" y2="${Y(50)}" stroke="rgba(255,255,255,0.06)"></line>
          <text x="3" y="11" fill="var(--faint)" font-size="9">100</text>
          <text x="3" y="${(Y(50)-2).toFixed(0)}" fill="var(--faint)" font-size="9">50</text>
          <path d="${area}" fill="url(#cf)"></path>
          <path d="${path}" fill="none" stroke="#a78bff" stroke-width="3" stroke-linecap="round"></path>
          ${nowLine}
          ${[minH, (minH+maxH)/2, maxH].map((h,i)=>`<text x="${i===0?3:i===2?W-3:X(h)}" y="${H-4}" fill="var(--faint)" font-size="9" text-anchor="${i===2?'end':i===1?'middle':'start'}">${Math.floor(h%24)}:00</text>`).join("")}
        </svg>
        <div class="legend"><span><i style="background:#8d73f2"></i>Deep-work window</span><span><i style="background:rgba(255,255,255,.4)"></i>Now (${fmtHour(nowH)})</span></div>
      </div>
      <div class="card"><h3>Deep-work windows</h3>${winList}</div>
      <div class="card"><h3>What's driving it</h3>${bar("Sleep pressure", Math.round(100*OP.CR.homeostatic((nowH-s.focusInp.wakeHour), s.focusInp.priorSleepMin, s.focusInp.sleepDebtMin)))}${bar("Body clock", Math.round(100*(OP.CR.circadian(nowH,s.focusInp.midpoint)+1.4)/2.8))}${bar("Calm (low stress)", Math.round(100-(s.str??50)))}</div>`;
  }
  function bar(label, val) {
    return `<div class="barrow"><div class="bh"><span>${label}</span><span class="muted">${val}</span></div><div class="track"><div class="fill" style="width:${OP.clamp(val,0,100)}%"></div></div></div>`;
  }

  function viewSleep(s) {
    if (D.totalSleepMin == null) return emptyState("No sleep data yet. Connect a data source and sync to see stages, performance and your bedtime plan.");
    const bedtime = (D.wakeHour ?? 7) - (s.need / 60);
    const stages = [["Deep", D.deepMin, "var(--purple)"], ["REM", D.remMin, "var(--purple-2)"], ["Light", D.coreMin, "var(--blue)"], ["Awake", D.awakeMin, "var(--faint)"]];
    const total = stages.reduce((a, x) => a + (x[1] || 0), 0) || 1;
    return `
      <div class="card center tappable" data-detail="sleepPerformance">
        <div class="bigring">${ring(s.sleepPerf, (s.sleepPerf||0)/100, "purple", 170, 14, s.sleepPerf ?? "—", fmtMin(D.totalSleepMin))}</div>
        <span class="pill purple">Sleep performance</span>
      </div>
      <div class="card"><h3>Stages</h3>
        <div style="display:flex;height:14px;border-radius:7px;overflow:hidden;margin-bottom:10px">
          ${stages.map(x=>`<div style="width:${((x[1]||0)/total*100).toFixed(1)}%;background:${x[2]}" title="${x[0]}"></div>`).join("")}
        </div>
        <div class="tiles">${stages.map(x=>`<div class="tile"><div class="v">${fmtMin(x[1])}</div><div class="l">${x[0]} · ${Math.round((x[1]||0)/total*100)}%</div></div>`).join("")}</div>
      </div>
      <div class="card"><h3>Quality</h3>
        <div class="tiles">
          <div class="tile"><div class="v">${D.efficiencyPct!=null?Math.round(D.efficiencyPct)+"%":"—"}</div><div class="l">Efficiency</div></div>
          <div class="tile"><div class="v">${D.restorativePct!=null?Math.round(D.restorativePct)+"%":"—"}</div><div class="l">Restorative</div></div>
          <div class="tile"><div class="v">${fmtMin(D.totalSleepMin)}</div><div class="l">Asleep</div></div>
          <div class="tile"><div class="v">${fmtMin(D.timeInBedMin)}</div><div class="l">In bed</div></div>
          <div class="tile"><div class="v">${D.sleepOnset?fmtHour(new Date(D.sleepOnset).getHours()+new Date(D.sleepOnset).getMinutes()/60):"—"}</div><div class="l">Asleep at</div></div>
          <div class="tile"><div class="v">${D.sleepWake?fmtHour(new Date(D.sleepWake).getHours()+new Date(D.sleepWake).getMinutes()/60):"—"}</div><div class="l">Woke at</div></div>
        </div>
      </div>
      <div class="card tappable" data-detail="sleepNeed"><h3>Need & bedtime</h3>
        <div class="row2">
          <div class="tile"><div class="v">${fmtMin(s.need)}</div><div class="l">Need tonight</div></div>
          <div class="tile"><div class="v">${fmtHour((bedtime+24)%24)}</div><div class="l">Suggested bedtime</div></div>
        </div>
        ${D.sleepDebtMin>10?`<div style="margin-top:10px"><span class="pill yellow">Sleep debt: ${fmtMin(D.sleepDebtMin)}</span></div>`:""}
        <div class="guidance">Dynamic model: baseline + today's strain + half of any sleep debt. Tap for details.</div>
      </div>
      ${(D.series && D.series.totalSleep && D.series.totalSleep.length>1) ? `<div class="card"><h3>Sleep duration trend</h3>${chart(D.series.totalSleep,{color:"purple",unit:"",fmt:(v)=>fmtMin(v)})}</div>` : ""}`;
  }

  function viewStrain(s) {
    if (D.dayStrain == null) return emptyState("No strain data yet. Connect a data source and sync — strain is computed from your heart rate through the day.");
    const z = OP.strainZone(D.dayStrain || 0);
    return `
      <div class="card center tappable" data-detail="strain">
        <div class="bigring">${ring(D.dayStrain, (D.dayStrain||0)/21, z.color, 180, 14, (D.dayStrain??0).toFixed(1), "Day strain")}</div>
        <span class="pill ${z.color}">${z.label}</span>
        <div class="guidance">0–21 cardiovascular load (TRIMP). Builds through the day. Tap for details.</div>
      </div>
      <div class="card"><h3>Load balance</h3>
        <div class="tiles">
          <div class="tile"><div class="v">${D.acwr!=null?D.acwr.toFixed(2):"—"}</div><div class="l">Acute:Chronic</div></div>
          <div class="tile"><div class="v">${D.acwr!=null?(D.acwr>=0.8&&D.acwr<=1.3?"Sweet spot":(D.acwr<0.8?"Detraining":"Caution")):"—"}</div><div class="l">Status</div></div>
          <div class="tile"><div class="v">${D.monotony!=null?D.monotony.toFixed(2):"—"}</div><div class="l">Monotony</div></div>
        </div>
        <div class="guidance">ACWR compares your last 7 days of load to your 28-day average; 0.8–1.3 is the sweet spot. Monotony (last 7 days) over 2.0 means too little day-to-day variation.</div>
      </div>
      ${(D.series && D.series.strain && D.series.strain.length>1) ? `<div class="card"><h3>Strain trend</h3>${chart(D.series.strain,{color:"blue",unit:"",fmt:(v)=>v.toFixed(1)})}</div>` : ""}`;
  }

  function viewSettings() {
    const w = CFG.recW;
    const wnum = (id, label, val) => `<label class="f">${label}</label><input class="f" id="${id}" type="number" step="0.05" min="0" max="1" value="${val}">`;
    return backBtn() + `
      <div class="card">
        <h3>Profile</h3>
        <label class="f">Age</label>
        <input class="f" id="cfgAge" type="number" min="13" max="120" value="${CFG.age}">
        <label class="f">Biological sex</label>
        <select class="f" id="cfgSex">
          <option value="male" ${CFG.sex === "male" ? "selected" : ""}>Male</option>
          <option value="female" ${CFG.sex === "female" ? "selected" : ""}>Female</option>
          <option value="other" ${CFG.sex === "other" ? "selected" : ""}>Other / prefer not to say</option>
        </select>
        <div class="guidance">Used for max-heart-rate and VO₂ norms.</div>
        <button class="btn" id="saveCfg">Save</button>
      </div>
      <div class="card">
        <h3>Recovery formula weights</h3>
        <div class="guidance" style="margin-top:0">How much each input counts toward your recovery score. Should add up to about 1.0.</div>
        ${wnum("wHrv", "HRV", w.hrv)}
        ${wnum("wRhr", "Resting HR", w.rhr)}
        ${wnum("wResp", "Respiratory rate", w.resp)}
        ${wnum("wSleep", "Sleep performance", w.sleep)}
        <button class="btn" id="saveCfg2">Save weights</button>
        <button class="btn ghost" id="resetCfg">Reset to defaults</button>
      </div>
      <div class="card">
        <h3>Connect Google Health</h3>
        <div class="guidance" style="margin-top:0">Your scores come only from synced data — no manual or sample data. Uses Google sign-in with no secret (a <b>Web</b> OAuth client whose <b>Authorized JavaScript origins</b> include this site).</div>
        <label class="f">Google Web OAuth client ID</label>
        <input class="f" id="ghClientId" placeholder="…apps.googleusercontent.com" value="${GH.getClientId()}">
        <div class="guidance" id="ghStatus">${GH.isSignedIn() ? (lastSyncMsg || "✅ Connected.") : "Not connected."}</div>
        ${GH.isSignedIn()
          ? `<button class="btn" data-action="sync" ${syncing ? "disabled" : ""}>${syncing ? "Syncing…" : "Sync now"}</button><button class="btn ghost" id="ghDiag">Test connection (diagnostics)</button><button class="btn ghost" id="ghDisconnect">Disconnect</button>`
          : `<button class="btn" id="ghConnect">Connect Google Health</button>`}
        <pre id="ghDiagOut" style="white-space:pre-wrap;font-size:.66rem;color:var(--dim);overflow:auto;max-height:260px;margin-top:10px"></pre>
        <div class="guidance" style="font-size:.78rem">Authorized JavaScript origin: <code>${GH.jsOrigin()}</code></div>
      </div>
      <div class="card">
        <h3>Data</h3>
        <div class="guidance" style="margin-top:0">All scores are computed on-device from synced data only.</div>
        <button class="btn ghost" id="clearBtn">Clear synced data</button>
      </div>
      <div class="card">
        <h3>Get the full app</h3>
        <a class="btn coffee" href="https://buymeacoffee.com/afonsodemello" target="_blank" rel="noopener" style="display:block;text-align:center;text-decoration:none">☕ Support the project</a>
        <a class="btn ghost" href="https://outperform.afonsodemello.com" target="_blank" rel="noopener" style="display:block;text-align:center;text-decoration:none;margin-top:10px">Visit the website</a>
      </div>`;
  }

  // ---------- Metric catalog (tap any metric for details) ----------
  const fmtScore = (v) => v == null ? "—" : `${Math.round(v)}`;
  const fmt1 = (v) => v == null ? "—" : v.toFixed(1);
  const METRICS = {
    readiness: { title: "Readiness", series: null,
      val: (s) => s.read, fmt: fmtScore, unit: "/100", zone: (v) => OP.recoveryZone(v),
      how: "One daily number for how primed you are. Readiness = recovery × 0.60 + sleep performance × 0.25 + a training-load (ACWR) factor × 0.15. The load factor is 100 inside the 0.8–1.3 acute:chronic sweet spot and tapers outside it.",
      inputs: (s) => [["Recovery", fmtScore(s.rec)], ["Sleep performance", fmtScore(s.sleepPerf)]] },
    recovery: { title: "Recovery", series: null,
      val: (s) => s.rec, fmt: fmtScore, unit: "%", zone: (v) => OP.recoveryZone(v),
      how: "Computed each morning from last night. A weighted blend of HRV (z vs your 3-day mean / 7-day std), resting HR, respiratory rate and sleep performance — each compared to your personal baseline — then mapped to 0–100. Elevated skin temperature and low blood-oxygen apply penalties. Weights are adjustable in Settings.",
      inputs: () => [["HRV", D.hrv != null ? `${Math.round(D.hrv)} ms` : "—"], ["Resting HR", D.restingHR != null ? `${Math.round(D.restingHR)} bpm` : "—"], ["Respiratory", D.respiratoryRate != null ? D.respiratoryRate.toFixed(1) : "—"], ["Blood oxygen", D.spo2Avg != null ? `${D.spo2Avg}%` : "—"]] },
    strain: { title: "Day strain", series: null,
      val: () => D.dayStrain, fmt: fmt1, unit: "/21", zone: (v) => OP.strainZone(v),
      how: "Cardiovascular load on a 0–21 logarithmic scale. Every minute of heart rate is placed in one of five zones (% of max HR) and weighted 1–5 (TRIMP). Strain = 4.8 × ln(1 + TRIMP/150), capped at 21. It builds from midnight, so it's low early in the day.",
      inputs: () => [["Acute:chronic ratio", D.acwr != null ? D.acwr.toFixed(2) : "—"]] },
    sleepPerformance: { title: "Sleep performance", series: null,
      val: (s) => s.sleepPerf, fmt: fmtScore, unit: "%", zone: () => ({ label: "Sleep", color: "purple" }),
      how: "How well you slept vs what you needed. Weighted blend of sleep efficiency (30%), restorative sleep — REM+deep, 40% = perfect (30%), need fulfilment — slept ÷ needed (25%) and bedtime consistency (15%).",
      inputs: () => [["Asleep", fmtMin(D.totalSleepMin)], ["Efficiency", D.efficiencyPct != null ? `${Math.round(D.efficiencyPct)}%` : "—"], ["Restorative", D.restorativePct != null ? `${Math.round(D.restorativePct)}%` : "—"]] },
    focus: { title: "Cognitive focus", series: null,
      val: (s) => Math.round(OP.CR.readiness(new Date().getHours() + new Date().getMinutes() / 60, s.focusInp)), fmt: fmtScore, unit: "/100", zone: (v) => OP.focusZone(v),
      how: "How “locked in” you can be right now, from the Three-Process Model of alertness: sleep pressure (falls the longer you're awake) + your body clock (peaks late-afternoon) + sleep inertia, nudged by HRV and stress. The Focus tab shows the full day curve.",
      inputs: () => [["Slept", fmtMin(D.totalSleepMin)], ["Wake time", D.wakeHour != null ? fmtHour(D.wakeHour) : "—"]] },
    hrv: { title: "HRV", series: "hrv",
      val: () => D.hrv, fmt: (v) => v == null ? "—" : `${Math.round(v)}`, unit: "ms", zone: null,
      how: "Heart-rate variability overnight — the strongest recovery signal. Higher generally means better-recovered. Recovery compares today's value to your rolling baseline." },
    restingHR: { title: "Resting HR", series: "restingHR",
      val: () => D.restingHR, fmt: (v) => v == null ? "—" : `${Math.round(v)}`, unit: "bpm", zone: null,
      how: "Your lowest heart rate overnight. Lower vs your baseline is better; a rise can signal fatigue, stress or illness." },
    respiratoryRate: { title: "Respiratory rate", series: "respiratoryRate",
      val: () => D.respiratoryRate, fmt: fmt1, unit: "br/min", zone: null,
      how: "Breaths per minute during sleep. Very stable night to night, so a jump above baseline is an early illness/strain signal." },
    spo2: { title: "Blood oxygen", series: null,
      val: () => D.spo2Avg, fmt: (v) => v == null ? "—" : `${v}`, unit: "%", zone: null,
      how: "Average overnight blood-oxygen saturation. Normal is ~95–100%. Low readings apply a recovery penalty." },
    skinTemp: { title: "Skin temperature", series: "skinTempC",
      val: () => D.skinTempC, fmt: fmt1, unit: "°C", zone: null,
      how: "Wrist/skin temperature during sleep, read as deviation from your 14-day baseline. More than +0.5°C applies a recovery penalty and can be an early illness signal." },
    stress: { title: "Stress", series: null,
      val: (s) => s.str, fmt: fmtScore, unit: "/100", zone: (v) => (v < 34 ? { label: "Calm", color: "green" } : v < 67 ? { label: "Moderate", color: "yellow" } : { label: "High", color: "red" }),
      how: "Autonomic stress from HRV and heart rate vs your 14-day baseline: raw = (−HRV_z × 0.65) + (HR_z × 0.35), mapped to 0–100. Lower HRV / higher HR than usual reads as more stress.",
      inputs: () => [["HRV", D.hrv != null ? `${Math.round(D.hrv)} ms` : "—"], ["Resting HR", D.restingHR != null ? `${Math.round(D.restingHR)} bpm` : "—"]] },
    sleepNeed: { title: "Sleep need", series: null,
      val: (s) => s.need, fmt: (v) => v == null ? "—" : fmtMin(v), unit: "", zone: null,
      how: "How much sleep you need tonight: your personal baseline + extra for today's strain + half of any sleep debt. Drives the suggested bedtime." },
    vo2max: { title: "VO₂ max", series: null,
      val: () => D.vo2Max, fmt: fmt1, unit: "ml/kg/min", zone: null,
      how: "Estimated maximal oxygen uptake — a key measure of cardiorespiratory fitness, read from your wearable. Higher is fitter; it changes slowly over weeks of training." },
  };

  let lastS = null;

  // ---------- Interactive charts (axes + hover) ----------
  let chartSeq = 0; const chartReg = {};
  function chart(points, opts) {
    const id = "ch" + (++chartSeq);
    chartReg[id] = { points: (points || []).filter((p) => p.v != null), opts: opts || {} };
    return `<div class="ichart" data-chart="${id}" style="position:relative"></div>`;
  }
  function renderCharts(root) {
    (root || document).querySelectorAll("[data-chart]").forEach((el) => {
      const cfg = chartReg[el.dataset.chart]; if (cfg) drawChart(el, cfg.points, cfg.opts);
    });
  }
  function drawChart(el, points, opts) {
    if (!points || points.length < 2) { el.innerHTML = `<div class="muted" style="font-size:.8rem;padding:6px 0">Trend builds as more days sync.</div>`; return; }
    const color = opts.color || "purple", fmt = opts.fmt || ((v) => `${Math.round(v)}`), unit = opts.unit || "";
    const W = Math.max(220, el.clientWidth || 300), H = 150, PL = 34, PB = 18, PT = 8, PR = 8;
    const vs = points.map((p) => p.v); let min = Math.min(...vs), max = Math.max(...vs); if (min === max) { min -= 1; max += 1; }
    const xs = points.map((p) => p.t), xmin = Math.min(...xs), xmax = Math.max(...xs), xspan = (xmax - xmin) || 1;
    const X = (t) => PL + ((t - xmin) / xspan) * (W - PL - PR);
    const Y = (v) => PT + (1 - (v - min) / (max - min)) * (H - PT - PB);
    const line = points.map((p, i) => `${i ? "L" : "M"} ${X(p.t).toFixed(1)} ${Y(p.v).toFixed(1)}`).join(" ");
    const area = `${line} L ${X(xmax).toFixed(1)} ${H - PB} L ${X(xmin).toFixed(1)} ${H - PB} Z`;
    const dlab = (t) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}`; };
    const grid = [max, (min + max) / 2, min].map((v) => `<line x1="${PL}" y1="${Y(v).toFixed(1)}" x2="${W - PR}" y2="${Y(v).toFixed(1)}" stroke="rgba(255,255,255,0.06)"/><text x="2" y="${(Y(v) + 3).toFixed(1)}" fill="var(--faint)" font-size="9">${fmt(v)}</text>`).join("");
    const xlab = `<text x="${PL}" y="${H - 5}" fill="var(--faint)" font-size="9">${dlab(xmin)}</text><text x="${W - PR}" y="${H - 5}" fill="var(--faint)" font-size="9" text-anchor="end">${dlab(xmax)}</text>`;
    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="100%" height="${H}" style="display:block;touch-action:none">
      <defs><linearGradient id="g${el.dataset.chart}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--${color})" stop-opacity="0.28"/><stop offset="1" stop-color="var(--${color})" stop-opacity="0"/></linearGradient></defs>
      ${grid}<path d="${area}" fill="url(#g${el.dataset.chart})"/>
      <path d="${line}" fill="none" stroke="var(--${color})" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>${xlab}
      <line class="cx" y1="${PT}" y2="${H - PB}" stroke="rgba(255,255,255,.45)" stroke-dasharray="3 3" style="display:none"/>
      <circle class="cd" r="4" fill="#fff" style="display:none"/></svg>
      <div class="ctip" style="position:absolute;pointer-events:none;display:none;background:var(--card-solid);border:1px solid var(--stroke-2);border-radius:8px;padding:4px 8px;font-size:.72rem;white-space:nowrap;transform:translate(-50%,-120%)"></div>`;
    const svg = el.querySelector("svg"), cx = el.querySelector(".cx"), cd = el.querySelector(".cd"), tip = el.querySelector(".ctip");
    const move = (clientX) => {
      const r = svg.getBoundingClientRect(), px = (clientX - r.left) / r.width * W;
      let best = points[0]; for (const p of points) if (Math.abs(X(p.t) - px) < Math.abs(X(best.t) - px)) best = p;
      const bx = X(best.t), by = Y(best.v);
      cx.setAttribute("x1", bx); cx.setAttribute("x2", bx); cx.style.display = ""; cd.setAttribute("cx", bx); cd.setAttribute("cy", by); cd.style.display = "";
      tip.style.display = "block"; tip.style.left = (bx / W * 100) + "%"; tip.style.top = (by / H * 100) + "%";
      tip.innerHTML = `<b>${fmt(best.v)}${unit ? " " + unit : ""}</b> · <span style="color:var(--faint)">${new Date(best.t).toLocaleDateString()}</span>`;
    };
    const onMove = (e) => move((e.touches ? e.touches[0] : e).clientX);
    const hide = () => { cx.style.display = "none"; cd.style.display = "none"; tip.style.display = "none"; };
    svg.addEventListener("mousemove", onMove); svg.addEventListener("mouseleave", hide);
    svg.addEventListener("touchstart", onMove, { passive: true }); svg.addEventListener("touchmove", onMove, { passive: true }); svg.addEventListener("touchend", hide);
  }

  function openDetail(kind) {
    const m = METRICS[kind]; if (!m) return;
    const v = m.val(lastS);
    const zone = (v != null && m.zone) ? m.zone(v) : null;
    const series = m.series && D.series ? D.series[m.series] : null;
    const inputs = m.inputs ? m.inputs(lastS) : [];
    document.getElementById("modal").innerHTML = `
      <div class="modal-card">
        <div class="mh"><h3>${m.title}</h3><button class="close" id="mClose">✕</button></div>
        <div class="bigval" style="color:${zone ? `var(--${zone.color})` : "var(--text)"}">${m.fmt(v)}<span style="font-size:1rem;color:var(--faint)"> ${m.unit}</span></div>
        ${zone ? `<span class="pill ${zone.color}">${zone.label}</span>` : ""}
        <div class="how">${m.how}</div>
        ${inputs.length ? `<div style="margin-bottom:12px">${inputs.map(([k, val]) => `<div class="detrow"><span class="k">${k}</span><span>${val}</span></div>`).join("")}</div>` : ""}
        ${series && series.length > 1 ? `<div style="font-size:.8rem;color:var(--faint);margin:6px 0 4px">Last ${series.length} days</div>${chart(series, { color: zone ? zone.color : "purple", unit: m.unit, fmt: m.fmt })}` : ""}
      </div>`;
    const modal = document.getElementById("modal");
    modal.classList.remove("hidden");
    renderCharts(modal);
    document.getElementById("mClose").onclick = closeModal;
    modal.onclick = (e) => { if (e.target === modal) closeModal(); };
  }
  function closeModal() { const m = document.getElementById("modal"); m.classList.add("hidden"); m.innerHTML = ""; }

  // ---------- Body / Trends / More ----------
  const backBtn = () => `<button class="backbtn" data-go="more">‹ More</button>`;

  function viewBody(s) {
    if (!hasData()) return backBtn() + ghBanner() + emptyState("Connect a data source and sync to see your body metrics.");
    return backBtn() + bodyBody(s);
  }
  function bodyBody(s) {
    const tile = (kind, label, val) => `<div class="tile tappable" data-detail="${kind}"><div class="v">${val}</div><div class="l">${label}</div></div>`;
    const sz = s.str != null ? (s.str < 34 ? "green" : s.str < 67 ? "yellow" : "red") : "blue";
    return `
      <div class="card center tappable" data-detail="stress">
        <div class="bigring">${ring(s.str, (s.str || 0) / 100, sz, 170, 14, s.str ?? "—", "Stress")}</div>
        <span class="pill ${sz}">${s.str != null ? (s.str < 34 ? "Calm" : s.str < 67 ? "Moderate" : "High") : "—"}</span>
        <div class="guidance">Tap any metric for how it's calculated.</div>
      </div>
      <h2 class="section">Vitals</h2>
      <div class="tiles">
        ${tile("hrv", "HRV", D.hrv != null ? Math.round(D.hrv) : "—")}
        ${tile("restingHR", "Resting HR", D.restingHR != null ? Math.round(D.restingHR) : "—")}
        ${tile("respiratoryRate", "Respiratory", D.respiratoryRate != null ? D.respiratoryRate.toFixed(1) : "—")}
        ${tile("spo2", "Blood O₂", D.spo2Avg != null ? D.spo2Avg + "%" : "—")}
        ${tile("skinTemp", "Skin temp", D.skinTempC != null ? D.skinTempC.toFixed(1) : "—")}
        ${tile("vo2max", "VO₂ max", D.vo2Max != null ? D.vo2Max.toFixed(1) : "—")}
        ${tile("strain", "Day strain", D.dayStrain != null ? D.dayStrain.toFixed(1) : "—")}
        ${tile("sleepNeed", "Sleep need", s.need != null ? fmtMin(s.need) : "—")}
      </div>`;
  }

  function viewTrends() {
    if (!D.series) return backBtn() + ghBanner() + emptyState("Connect a data source and sync to see your trends.");
    return backBtn() + trendsBody();
  }
  function trendsBody() {
    // [series key, label, unit, color, detail kind, format]
    const cards = [
      ["readiness", "Readiness", "", "purple", "readiness", (v) => Math.round(v)],
      ["recovery", "Recovery", "%", "green", "recovery", (v) => Math.round(v)],
      ["strain", "Day strain", "", "blue", "strain", (v) => v.toFixed(1)],
      ["sleepPerformance", "Sleep performance", "%", "purple", "sleepPerformance", (v) => Math.round(v)],
      ["totalSleep", "Sleep duration", "", "purple", "sleepPerformance", (v) => fmtMin(v)],
      ["stress", "Stress", "", "yellow", "stress", (v) => Math.round(v)],
      ["hrv", "HRV", "ms", "purple", "hrv", (v) => Math.round(v)],
      ["restingHR", "Resting HR", "bpm", "blue", "restingHR", (v) => Math.round(v)],
      ["respiratoryRate", "Respiratory rate", "br/min", "cyan", "respiratoryRate", (v) => v.toFixed(1)],
      ["skinTempC", "Skin temperature", "°C", "yellow", "skinTemp", (v) => v.toFixed(1)],
      ["spo2Avg", "Blood oxygen", "%", "cyan", "spo2", (v) => Math.round(v)],
    ];
    const body = cards.map(([key, label, unit, color, detail, fmt]) => {
      const ser = (D.series[key] || []);
      if (ser.length < 2) return "";
      const lastVal = ser[ser.length - 1].v;
      return `<div class="trend tappable" data-detail="${detail}">
        <div class="th"><span>${label}</span><b>${fmt(lastVal)}${unit ? " " + unit : ""}</b></div>
        ${chart(ser, { color, unit, fmt })}
      </div>`;
    }).join("");
    return `<h2 class="section">Trends</h2><div class="guidance" style="margin:0 4px 12px">Your last ${(D.series.hrv || []).length} days · drag across a chart for any day. Tap a card for details.</div>${body || `<div class="muted">Trends build as more days sync.</div>`}`;
  }

  function viewMore() {
    const row = (tab, icon, label) => `<div class="rowlink" data-go="${tab}"><div class="lv"><span class="ic">${icon}</span><span>${label}</span></div><span class="chev">›</span></div>`;
    return `
      <div class="card" style="padding:6px 16px">
        ${row("body", "🫀", "Body")}
        ${row("trends", "📈", "Trends")}
        ${row("settings", "⚙️", "Settings")}
      </div>
      <h2 class="section">Support OutPerform</h2>
      <div class="card">
        <div class="guidance" style="margin-top:0">OutPerform is free, private and on-device. If it helps you, a tip keeps it going 💜</div>
        <a class="btn" href="https://revolut.me/afonsodemello" target="_blank" rel="noopener" style="display:block;text-align:center;text-decoration:none">♥ Support via Revolut</a>
        <a class="btn coffee" href="https://buymeacoffee.com/afonsodemello" target="_blank" rel="noopener" style="display:block;text-align:center;text-decoration:none;margin-top:10px">☕ Buy me a coffee</a>
        <a class="btn ghost" href="https://outperform.afonsodemello.com" target="_blank" rel="noopener" style="display:block;text-align:center;text-decoration:none;margin-top:10px">Visit the website</a>
      </div>`;
  }

  // ---------- Install banner ----------
  let deferredPrompt = null;
  const isStandalone = window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true;
  const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent);
  function installBanner() {
    if (isStandalone) return "";
    if (deferredPrompt) return `<div class="install"><b>Install OutPerform</b> for a full-screen, app-like experience. <button class="btn" id="installBtn" style="margin-top:10px">Add to home screen</button></div>`;
    if (isIOS) return `<div class="install"><b>Add to Home Screen:</b> tap the Share button, then “Add to Home Screen,” to install OutPerform like an app.</div>`;
    return "";
  }
  window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); deferredPrompt = e; if (current === "today") render(); });

  // Google Health connection banner (shown on Today).
  function ghBanner() {
    if (GH.isSignedIn()) {
      const note = lastSyncMsg || (!hasData() ? "Connected — tap Sync to load your Google Health data." : "Connected to Google Health.");
      return `<div class="install">
        <div style="display:flex;align-items:center;gap:8px"><span style="width:9px;height:9px;border-radius:50%;background:var(--green);display:inline-block"></span> <b>Google Health connected</b></div>
        <div class="guidance" style="margin:6px 0 0">${note}</div>
        <button class="btn" data-action="sync" ${syncing ? "disabled" : ""}>${syncing ? "Syncing…" : "Sync now"}</button>
      </div>`;
    }
    return `<div class="install"><b>No data yet.</b> Connect Google Health to load your real data — OutPerform shows no sample data. <button class="btn" data-action="goData">Connect Google Health</button></div>`;
  }

  // ---------- Router ----------
  let current = "today";
  let syncing = false;
  let lastSyncMsg = "";
  function render() {
    const s = compute();
    lastS = s;
    const view = document.getElementById("view");
    const map = { today: viewToday, focus: viewFocus, sleep: viewSleep, strain: viewStrain,
                  more: viewMore, body: viewBody, trends: viewTrends, settings: viewSettings };
    view.innerHTML = (map[current] || viewToday)(s);
    window.scrollTo(0, 0);
    animateRings();
    wireView();
    updateHeader();
  }

  function updateHeader() {
    const el = document.getElementById("syncText");
    const dot = document.querySelector("#sync .dot");
    if (syncing) { el.textContent = "Syncing…"; if (dot) dot.style.background = "var(--yellow)"; return; }
    if (GH.isSignedIn()) { el.textContent = hasData() ? "Google Health" : "Connected · sync needed"; if (dot) dot.style.background = "var(--green)"; }
    else { el.textContent = hasData() ? "Manual data" : "No data — sync needed"; if (dot) dot.style.background = "var(--faint)"; }
  }

  function wireView() {
    const ib = document.getElementById("installBtn");
    if (ib) ib.onclick = async () => { if (deferredPrompt) { deferredPrompt.prompt(); deferredPrompt = null; } };
    const num = (id) => { const el = document.getElementById(id); if (!el) return null; const v = parseFloat(el.value); return isNaN(v) ? null : v; };
    const saveSettings = () => {
      const age = num("cfgAge"); if (age != null) CFG.age = OP.clamp(age, 13, 120);
      const sexEl = document.getElementById("cfgSex"); if (sexEl) CFG.sex = sexEl.value;
      const w = { hrv: num("wHrv"), rhr: num("wRhr"), resp: num("wResp"), sleep: num("wSleep") };
      Object.keys(w).forEach((k) => { if (w[k] != null) CFG.recW[k] = w[k]; });
      saveCfg(); render();
    };
    const sc1 = document.getElementById("saveCfg"); if (sc1) sc1.onclick = saveSettings;
    const sc2 = document.getElementById("saveCfg2"); if (sc2) sc2.onclick = saveSettings;
    const rc = document.getElementById("resetCfg");
    if (rc) rc.onclick = () => { CFG.recW = { ...OP.DEFAULT_RECOVERY_WEIGHTS }; saveCfg(); render(); };

    const cb = document.getElementById("clearBtn");
    if (cb) cb.onclick = () => { localStorage.removeItem(KEY); D = emptyData(); lastSyncMsg = ""; render(); };

    const diag = document.getElementById("ghDiag");
    if (diag) diag.onclick = async () => {
      const out = document.getElementById("ghDiagOut");
      if (out) out.textContent = "Running diagnostics…";
      try { const r = await GH.diagnostics(); if (out) out.textContent = r; }
      catch (e) { if (out) out.textContent = "⚠️ " + e.message; }
    };

    const cidEl = document.getElementById("ghClientId");
    const persistCid = () => { if (cidEl) GH.setClientId(cidEl.value); };
    const conn = document.getElementById("ghConnect");
    if (conn) conn.onclick = async () => {
      persistCid();
      try { await GH.signIn(); lastSyncMsg = ""; render(); syncGoogle(); }
      catch (e) { setGhStatus("⚠️ " + e.message); }
    };
    const disc = document.getElementById("ghDisconnect");
    if (disc) disc.onclick = () => { GH.signOut(); lastSyncMsg = ""; render(); };
    document.querySelectorAll('[data-action="sync"]').forEach((b) => (b.onclick = () => syncGoogle()));
    document.querySelectorAll('[data-action="goData"]').forEach((b) => (b.onclick = () => { current = "settings"; setActive(); render(); }));
    document.querySelectorAll("[data-detail]").forEach((el) => (el.onclick = () => openDetail(el.dataset.detail)));
    document.querySelectorAll("[data-go]").forEach((el) => (el.onclick = () => { current = el.dataset.go; setActive(); render(); }));
    renderCharts();
  }

  function setGhStatus(msg) { const el = document.getElementById("ghStatus"); if (el) el.textContent = msg; }

  async function syncGoogle() {
    if (syncing) return;
    syncing = true;
    render(); // disables buttons, shows "Syncing…" in banner + header
    try {
      const { days, vo2Max, errors } = await GH.fetchLatest(CFG.age || 30);
      if (days && days.length) {
        D.rawDays = days; D.vo2Max = vo2Max; D.date = new Date().toISOString();
        save_();
        lastSyncMsg = `✅ Synced ${days.length} days of data.`;
      } else {
        const blocked = errors.some((e) => /Failed to fetch|NetworkError|Load failed|CORS/i.test(e));
        lastSyncMsg = blocked
          ? "⚠️ Connected, but the browser blocked the data requests (CORS). Google Health isn't allowing direct browser calls — a small proxy is needed (I can add one)."
          : "Connected, but no data came back" + (errors[0] ? `: ${errors[0]}` : ". Your account may have no recent data for these types.");
      }
    } catch (e) {
      lastSyncMsg = "⚠️ " + e.message;
    }
    syncing = false;
    render();
  }
  function save_() { save(D); }

  function setActive() {
    const moreSet = ["more", "body", "trends", "settings"];
    document.querySelectorAll("#tabs button").forEach((b) => {
      const on = b.dataset.tab === current || (b.dataset.tab === "more" && moreSet.includes(current));
      b.classList.toggle("active", on);
    });
  }
  document.getElementById("tabs").addEventListener("click", (e) => {
    const btn = e.target.closest("button"); if (!btn) return;
    current = btn.dataset.tab; setActive(); render();
  });

  // Re-render Focus live as the day progresses / on return to foreground.
  setInterval(() => { if (current === "focus") render(); }, 60000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) render(); });

  // Init: render, and if already connected to Google Health, refresh data.
  render();
  if (GH.isSignedIn()) syncGoogle();
})();
