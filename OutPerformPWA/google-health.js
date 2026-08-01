/* OutPerform PWA — Google Health Web OAuth + data client.
   Browser PKCE flow (public client, no secret) against the Google Health API
   (health.googleapis.com/v4). Mirrors the native app's per-record-kind filter
   syntax and schema-resilient parsing.

   SETUP: in Google Cloud Console create a *Web application* OAuth client and add
   this page's URL as an Authorized redirect URI and JavaScript origin. Paste that
   Web client ID in the app (Data tab). The iOS client ID will NOT work for web. */

const GH = (() => {
  const SCOPES = [
    "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
    "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
    "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
    "https://www.googleapis.com/auth/googlehealth.profile.readonly",
  ];
  const BASE = "https://health.googleapis.com/v4/users/me";
  const K = { clientId: "gh_client_id", token: "gh_token", verifier: "gh_pkce_verifier", state: "gh_oauth_state" };

  // Baked-in Web OAuth client ID (overridable via the Data tab / localStorage).
  const DEFAULT_CLIENT_ID = "60854628435-1cpg9of5u1tiqhdqre3fo6shg2i4prga.apps.googleusercontent.com";

  const jsOrigin = () => location.origin;
  const getClientId = () => localStorage.getItem(K.clientId) || DEFAULT_CLIENT_ID;
  const setClientId = (id) => localStorage.setItem(K.clientId, id.trim());
  const isConfigured = () => getClientId().includes("apps.googleusercontent.com");

  function getToken() {
    try {
      const t = JSON.parse(localStorage.getItem(K.token) || "null");
      if (t && t.access_token && t.expiry > Date.now() + 60000) return t.access_token;
    } catch (e) {}
    return null;
  }
  const isSignedIn = () => !!getToken();
  function signOut() { localStorage.removeItem(K.token); }

  // ---- Google Identity Services token model ----
  // Public client-side flow: NO client secret, NO backend, NO code exchange.
  // Google returns an access token straight to the browser via its popup.
  let tokenClient = null, tokenClientId = null;
  const gisReady = () => !!(window.google && google.accounts && google.accounts.oauth2);
  function ensureClient() {
    if (!gisReady()) throw new Error("Google sign-in is still loading — wait a second and tap again.");
    if (!isConfigured()) throw new Error("Enter your Google Web OAuth client ID first.");
    if (tokenClient && tokenClientId === getClientId()) return tokenClient;
    tokenClientId = getClientId();
    tokenClient = google.accounts.oauth2.initTokenClient({
      client_id: tokenClientId,
      scope: SCOPES.join(" "),
      callback: () => {},
    });
    return tokenClient;
  }

  // Must be invoked from a user gesture (button click) so the popup isn't blocked.
  function signIn() {
    return new Promise((resolve, reject) => {
      let client;
      try { client = ensureClient(); } catch (e) { return reject(e); }
      client.callback = (resp) => {
        if (resp && resp.error) return reject(new Error(resp.error_description || resp.error));
        if (!resp || !resp.access_token) return reject(new Error("No access token returned."));
        localStorage.setItem(K.token, JSON.stringify({
          access_token: resp.access_token,
          expiry: Date.now() + ((resp.expires_in || 3600) * 1000),
        }));
        resolve(true);
      };
      client.requestAccessToken({ prompt: getToken() ? "" : "consent" });
    });
  }

  // ---- low-level dataPoints fetch ----
  const snake = (k) => k.replace(/-/g, "_");
  const camel = (k) => { const p = k.split("-"); return p[0] + p.slice(1).map((s) => s[0].toUpperCase() + s.slice(1)).join(""); };
  const rfc3339 = (d) => d.toISOString().replace(/\.\d+Z$/, "Z");
  const civil = (d) => d.toISOString().slice(0, 10);

  function recordKind(t) {
    if (["heart-rate", "oxygen-saturation", "vo2-max", "respiratory-rate-sleep-summary"].includes(t)) return "sample";
    if (["sleep", "exercise"].includes(t)) return "session";
    return t.startsWith("daily-") ? "daily" : "sample";
  }
  function filterExpr(t, from, to) {
    const s = snake(t);
    switch (recordKind(t)) {
      case "sample": return `${s}.sample_time.physical_time >= "${rfc3339(from)}" AND ${s}.sample_time.physical_time < "${rfc3339(to)}"`;
      case "daily": return `${s}.date >= "${civil(from)}" AND ${s}.date < "${civil(to)}"`;
      default: return null; // session: no filter, match client-side
    }
  }

  async function dataPoints(type, from, to, maxPoints = 20000) {
    const token = getToken();
    if (!token) throw new Error("Not signed in to Google Health.");
    const filter = filterExpr(type, from, to);
    let out = [], pageToken = null;
    do {
      const qs = new URLSearchParams({ pageSize: "1000" });
      if (filter) qs.set("filter", filter);
      if (pageToken) qs.set("pageToken", pageToken);
      const res = await fetch(`${BASE}/dataTypes/${type}/dataPoints?${qs}`, { headers: { Authorization: "Bearer " + token } });
      if (res.status === 401) { signOut(); throw new Error("Google session expired — connect again."); }
      if (res.status === 403) throw new Error(`Scope not granted for ${type}.`);
      if (!res.ok) break; // type with no data/permission → treat as empty
      const j = await res.json();
      if (j.dataPoints) out = out.concat(j.dataPoints);
      pageToken = j.nextPageToken;
    } while (pageToken && out.length < maxPoints);
    return out;
  }

  // ---- parsing helpers (robust to Google's actual JSON shapes) ----
  function findNumber(obj, key) {
    if (obj == null || typeof obj !== "object") return null;
    if (typeof obj[key] === "number") return obj[key];
    if (typeof obj[key] === "string" && obj[key] !== "" && !isNaN(+obj[key])) return +obj[key];
    for (const v of Object.values(obj)) { const r = findNumber(v, key); if (r != null) return r; }
    return null;
  }
  const metricKey = (t) => ({
    "heart-rate": "beatsPerMinute", "daily-resting-heart-rate": "beatsPerMinute",
    "daily-heart-rate-variability": "averageHeartRateVariabilityMilliseconds",
    "oxygen-saturation": "percentage", "vo2-max": "vo2Max",
    "respiratory-rate-sleep-summary": "breathsPerMinute",
    "daily-sleep-temperature-derivations": "nightlyTemperatureCelsius",
  }[t]);

  // Time can be: an ISO string, a google.type.Date {year,month,day}, or a
  // protobuf Timestamp {seconds,nanos}. Walk the point and return the first one,
  // preferring keys that look like a time/date.
  function extractTime(p) {
    let found = null, fallback = null;
    (function walk(node, key) {
      if (found || node == null) return;
      if (typeof node === "string") {
        if (/^\d{4}-\d{2}-\d{2}T/.test(node)) { const d = new Date(node); if (!isNaN(d)) { if (/(time|date)/i.test(key)) found = d; else fallback = fallback || d; } }
        return;
      }
      if (typeof node !== "object") return;
      if (typeof node.year === "number" && typeof node.month === "number" && typeof node.day === "number") {
        const d = new Date(Date.UTC(node.year, node.month - 1, node.day, 12, 0, 0));
        if (/(time|date)/i.test(key)) found = d; else fallback = fallback || d; return;
      }
      if (node.seconds != null && (typeof node.seconds === "number" || /^\d+$/.test(node.seconds))) {
        const d = new Date(Number(node.seconds) * 1000);
        if (/(time|date)/i.test(key)) found = d; else fallback = fallback || d; return;
      }
      for (const k in node) { walk(node[k], k); if (found) return; }
    })(p, "");
    return found || fallback;
  }

  // The metric number: prefer the known field; otherwise the first number that
  // isn't part of a date/time/metadata subtree.
  function extractValue(obj, key) {
    if (key) { const v = findNumber(obj, key); if (v != null) return v; }
    let found = null;
    (function walk(node, k) {
      if (found != null || node == null) return;
      if (typeof node === "number") { if (!/(year|month|day|hour|minute|second|nano|offset|utc|count|confidence)/i.test(k)) found = node; return; }
      if (typeof node !== "object") return;
      if (/(time|date|interval|source|device|application)/i.test(k)) return;
      for (const kk in node) { walk(node[kk], kk); if (found != null) return; }
    })(obj, "");
    return found;
  }

  function samples(points, type) {
    const field = camel(type), key = metricKey(type);
    return points.map((p) => {
      const obj = p[field] || p;
      const v = extractValue(obj, key);
      const t = extractTime(p);
      return v != null && t ? { t, v } : null;
    }).filter(Boolean).sort((a, b) => a.t - b.t);
  }

  // ---- high level: pull latest + baselines into a data update ----
  // Local calendar-day key, e.g. "2026-06-11".
  function dayKey(dt) {
    const d = new Date(dt);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  }

  // Returns aligned per-day data for the engine to walk chronologically.
  async function fetchLatest(age = 30) {
    const now = new Date();
    const back = (d) => new Date(now.getTime() - d * 86400000);
    const errs = [];
    const tryGet = async (label, fn) => { try { return await fn(); } catch (e) { errs.push(`${label}: ${e.message}`); return null; } };

    const days = {};                                  // dayKey -> { date, hrv, restingHR, ... }
    const ensure = (k) => (days[k] = days[k] || { date: k });

    const hrv = samples(await tryGet("HRV", () => dataPoints("daily-heart-rate-variability", back(30), now)) || [], "daily-heart-rate-variability");
    const rhr = samples(await tryGet("RHR", () => dataPoints("daily-resting-heart-rate", back(30), now)) || [], "daily-resting-heart-rate");
    const resp = samples(await tryGet("Respiratory", () => dataPoints("respiratory-rate-sleep-summary", back(30), now)) || [], "respiratory-rate-sleep-summary");
    const temp = samples(await tryGet("Temp", () => dataPoints("daily-sleep-temperature-derivations", back(30), now)) || [], "daily-sleep-temperature-derivations");
    for (const x of hrv) ensure(dayKey(x.t)).hrv = +x.v.toFixed(1);
    for (const x of rhr) ensure(dayKey(x.t)).restingHR = Math.round(x.v);
    for (const x of resp) ensure(dayKey(x.t)).respiratoryRate = +x.v.toFixed(1);
    for (const x of temp) ensure(dayKey(x.t)).skinTempC = +x.v.toFixed(2);

    // Sleep nights (30d), keyed by wake/morning date.
    const nights = collectNights(await tryGet("Sleep", () => dataPoints("sleep", back(30), now)) || []);
    for (const n of nights) { const d = ensure(dayKey(n.end)); d.sleep = n.metrics; d.sleepStart = n.start.getTime(); d.sleepEnd = n.end.getTime(); }

    // SpO2 (30d), averaged per day.
    const spo2 = samples(await tryGet("SpO2", () => dataPoints("oxygen-saturation", back(30), now)) || [], "oxygen-saturation").filter((x) => x.v >= 70 && x.v <= 100);
    const spo2Day = {};
    for (const x of spo2) (spo2Day[dayKey(x.t)] = spo2Day[dayKey(x.t)] || []).push(x.v);
    for (const k in spo2Day) ensure(k).spo2Avg = +OP.mean(spo2Day[k]).toFixed(1);

    // Heart rate over 30d → per-day strain (minute-bucket TRIMP, personalised HRmax).
    const hr = samples(await tryGet("HeartRate", () => dataPoints("heart-rate", back(30), now, 80000)) || [], "heart-rate");
    if (hr.length > 50) {
      const hrMax = OP.personalisedHRMax(age, hr.map((x) => x.v), "max");
      const hrDay = {};
      for (const x of hr) (hrDay[dayKey(x.t)] = hrDay[dayKey(x.t)] || []).push(x);
      for (const k in hrDay) ensure(k).dayStrain = +OP.strainFromTRIMP(OP.trimpFromSamples(hrDay[k], hrMax)).toFixed(1);
    }

    // VO2 max (latest over 90d).
    const vo2 = samples(await tryGet("VO2", () => dataPoints("vo2-max", back(90), now)) || [], "vo2-max");
    const vo2Max = vo2.length ? +vo2[vo2.length - 1].v.toFixed(1) : null;

    const arr = Object.values(days).sort((a, b) => (a.date < b.date ? -1 : 1));
    return { days: arr, vo2Max, age, errors: errs };
  }

  // Dedupe overlapping sleep sessions (multi-source), newest last, with per-night metrics.
  function collectNights(points) {
    const sessions = [];
    for (const p of points) {
      const sObj = p.sleep || p;
      const iv = sObj.interval || {};
      const s = iv.startTime ? new Date(iv.startTime) : null;
      const e = iv.endTime ? new Date(iv.endTime) : null;
      if (!s || !e || isNaN(s) || isNaN(e)) continue;
      sessions.push({ s, e, stages: sObj.stages || [] });
    }
    sessions.sort((a, b) => a.s - b.s);
    const kept = [];
    for (const ss of sessions) {
      const last = kept[kept.length - 1];
      if (last && last.s < ss.e && ss.s < last.e) { if (ss.stages.length > last.stages.length) kept[kept.length - 1] = ss; }
      else kept.push(ss);
    }
    return kept.map((ss) => ({ start: ss.s, end: ss.e, metrics: nightMetrics(ss) }));
  }

  function nightMetrics(ss) {
    const acc = { deepMin: 0, remMin: 0, coreMin: 0, awakeMin: 0 };
    let asleep = 0, inbed = 0;
    for (const st of ss.stages) {
      const a = new Date(st.startTime), b = new Date(st.endTime);
      if (isNaN(a) || isNaN(b)) continue;
      const min = Math.max(0, (b - a) / 60000);
      const T = (st.type || "").toUpperCase();
      const key = T.includes("DEEP") ? "deepMin" : T.includes("REM") ? "remMin" : (T.includes("AWAKE") || T.includes("RESTLESS")) ? "awakeMin" : "coreMin";
      acc[key] += min; inbed += min;
      if (key !== "awakeMin") asleep += min;
    }
    if (inbed === 0) { const min = (ss.e - ss.s) / 60000; asleep = min; inbed = min; acc.coreMin = min; }
    return {
      totalSleepMin: Math.round(asleep), timeInBedMin: Math.round(inbed),
      deepMin: Math.round(acc.deepMin), remMin: Math.round(acc.remMin), coreMin: Math.round(acc.coreMin), awakeMin: Math.round(acc.awakeMin),
      efficiencyPct: inbed ? Math.min(100, (asleep / inbed) * 100) : 0,
      restorativePct: asleep ? ((acc.deepMin + acc.remMin) / asleep) * 100 : 0,
      wakeHour: ss.e.getHours() + ss.e.getMinutes() / 60,
      sleepMidpoint: new Date((ss.s.getTime() + ss.e.getTime()) / 2).getHours(),
    };
  }

  // ---- diagnostics: per-type HTTP status + count, to see what's not coming back ----
  async function diagnostics() {
    const token = getToken();
    if (!token) return "Not signed in.";
    const now = new Date();
    const from = new Date(now.getTime() - 4 * 86400000);
    const types = [
      "daily-heart-rate-variability", "daily-resting-heart-rate",
      "respiratory-rate-sleep-summary", "oxygen-saturation",
      "daily-sleep-temperature-derivations", "heart-rate", "sleep", "vo2-max",
    ];
    let report = `Diagnostics ${now.toISOString()}\norigin: ${location.origin}\n`;
    for (const t of types) {
      const filter = filterExpr(t, from, now);
      const qs = new URLSearchParams({ pageSize: "3" });
      if (filter) qs.set("filter", filter);
      try {
        const res = await fetch(`${BASE}/dataTypes/${t}/dataPoints?${qs}`, { headers: { Authorization: "Bearer " + token } });
        const text = await res.text();
        let count = "?";
        try { count = (JSON.parse(text).dataPoints || []).length; } catch (e) {}
        report += `\n[${t}] HTTP ${res.status}  points=${count}\n${text.slice(0, 700)}\n`;
      } catch (e) {
        report += `\n[${t}] FETCH ERROR: ${e.message}  (likely CORS — browser blocked it)\n`;
      }
    }
    return report;
  }

  return { SCOPES, getClientId, setClientId, isConfigured, isSignedIn, signOut, signIn, fetchLatest, diagnostics, jsOrigin };
})();
