/* =====================================================================
   neptsbi.js — shared code for every neptsBI page
   (database connection, who is signed in, formatting, ⋮ menu extras)

   Load after dougs.js and supabase-js:
     <script src="dougs.js"></script>
     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>
     <script src="neptsbi.js"></script>
   ===================================================================== */

(function () {
  "use strict";

  /* ---- SUPABASE CONNECTION (same project as the parking app) ----
     The key is the public "publishable" key; the database's security
     rules decide what it can do. */
  var SUPABASE_URL = "https://vruayefwgzwlwestsedo.supabase.co";
  var SUPABASE_KEY = "sb_publishable_AWpInxkGOBc1bWFsJQjB_g_vBKftpm9";

  var AS_KEY = "neptsbi.as";

  function load(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
  function save(key, value) {
    try { if (value === null) localStorage.removeItem(key); else localStorage.setItem(key, value); }
    catch (e) { /* not remembered; the ?as= link still works */ }
  }

  /* ---- Who is signed in: ?as=code wins and is remembered ---- */
  var params = new URLSearchParams(location.search);
  if (params.has("as")) save(AS_KEY, params.get("as") || null);

  var db = null;
  if (window.supabase && window.supabase.createClient) {
    db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, { db: { schema: "neptsbi" } });
  }

  /* ---- Formatting ---- */
  function esc(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#039;");
  }

  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  // Dates arrive as "2026-10-13"; read them as plain calendar dates (no time-zone shifts)
  function parseDate(s) {
    if (!s) return null;
    var p = String(s).slice(0, 10).split("-");
    return new Date(+p[0], +p[1] - 1, +p[2]);
  }
  function fmtDate(s) {
    var d = parseDate(s);
    return d ? d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear() : "–";
  }
  function fmtDateTime(s) {
    if (!s) return "–";
    var d = new Date(s);
    return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear() + ", " +
      String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  }
  function isoToday(offsetDays) {
    var d = new Date();
    d.setDate(d.getDate() + (offsetDays || 0));
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  }
  function fmtNum(n) { return n == null ? "–" : Number(n).toLocaleString("en-GB"); }

  function daysText(days) {
    if (days == null) return "";
    if (days < -1) return Math.abs(days) + " days overdue";
    if (days === -1) return "1 day overdue";
    if (days === 0) return "due today";
    if (days === 1) return "due tomorrow";
    return "in " + days + " days";
  }

  var STATUS_CLASS = { "Overdue": "danger", "Due soon": "warn", "OK": "ok" };
  function statusBadge(status) {
    return '<span class="badge badge--' + (STATUS_CLASS[status] || "neutral") + '">' + esc(status) + "</span>";
  }
  function bookingBadge(row) {
    if (row.status === "OK" && !row.booked && !row.retest) return "";
    if (row.awaiting_result) return '<span class="badge badge--warn">Result to log</span>';
    return row.booked
      ? '<span class="badge badge--info">Booked ' + esc(fmtDate(row.booking_date)) + "</span>"
      : '<span class="badge badge--neutral">Not booked</span>';
  }

  function friendlyError(error) {
    var msg = (error && (error.message || error.details)) || String(error || "Something went wrong");
    if (/schema must be one of|not exposed|Invalid schema/i.test(msg)) {
      return "The database isn't switched on for the app yet (Supabase: add “neptsbi” to the exposed schemas – see SETUP step 2).";
    }
    if (/Failed to fetch|NetworkError/i.test(msg)) return "Can't reach the database – check the connection and try again.";
    return msg;
  }


  /* ---- Small bar chart (one series): SVG that scales to its box ----
     data: [{ label, value, tip }]; labels shown every `labelEvery` bars.
     Hover/tap a bar for its tooltip. Use with a "Show as table" toggle. */
  function niceMax(v) {
    if (v <= 0) return 1;
    var p = Math.pow(10, Math.floor(Math.log10(v))), n = v / p;
    return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
  }
  function barChart(data, opts) {
    opts = opts || {};
    var W = opts.width || 400, H = opts.height || 200, L = 46, B = 26, T = 8, R = 4;
    var max = niceMax(Math.max.apply(null, data.map(function (d) { return d.value; }).concat([0])));
    var n = data.length, slot = (W - L - R) / Math.max(n, 1), gap = 2, bw = Math.max(1, slot - gap);
    var y = function (v) { return T + (H - T - B) * (1 - v / max); };
    var every = opts.labelEvery || Math.ceil(n / 8);
    var out = '<svg class="chart" viewBox="0 0 ' + W + " " + H + '" role="img" aria-label="' + esc(opts.ariaLabel || "") + '">';
    [0, 0.5, 1].forEach(function (f) {
      var gy = y(max * f);
      out += '<line class="chart__grid" x1="' + L + '" x2="' + (W - R) + '" y1="' + gy + '" y2="' + gy + '"/>' +
             '<text class="chart__axis" x="' + (L - 6) + '" y="' + (gy + 4) + '" text-anchor="end">' + fmtNum(Math.round(max * f)) + "</text>";
    });
    data.forEach(function (d, i) {
      var x = L + i * slot + gap / 2, top = y(d.value), h = Math.max(0, H - B - top), r = Math.min(4, bw / 2, h);
      if (h > 0) {
        out += '<path class="chart__bar" d="M' + x + "," + (H - B) + "V" + (top + r) + "Q" + x + "," + top + " " + (x + r) + "," + top +
               "H" + (x + bw - r) + "Q" + (x + bw) + "," + top + " " + (x + bw) + "," + (top + r) + "V" + (H - B) + 'Z"/>';
      }
      // Hit area: the whole column, easier to hover/tap than the bar itself
      out += '<rect class="chart__hit" x="' + (L + i * slot) + '" y="' + T + '" width="' + slot + '" height="' + (H - T - B) +
             '" data-tip="' + esc(d.tip || (d.label + ": " + fmtNum(d.value))) + '"/>';
      if (i % every === 0) out += '<text class="chart__axis" x="' + (x + bw / 2) + '" y="' + (H - 8) + '" text-anchor="middle">' + esc(d.label) + "</text>";
    });
    out += '<line class="chart__base" x1="' + L + '" x2="' + (W - R) + '" y1="' + (H - B) + '" y2="' + (H - B) + '"/></svg>';
    return out;
  }
  function chartTable(rows, headers) {
    return '<details class="chart-table"><summary>Show as table</summary><div class="table-wrap"><table class="table">' +
      "<thead><tr>" + headers.map(function (h, i) { return "<th" + (i ? ' class="num"' : "") + ">" + esc(h) + "</th>"; }).join("") + "</tr></thead><tbody>" +
      rows.map(function (r) { return "<tr>" + r.map(function (c, i) { return "<td" + (i ? ' class="num"' : "") + ">" + esc(c) + "</td>"; }).join("") + "</tr>"; }).join("") +
      "</tbody></table></div></details>";
  }
  // One shared tooltip for every chart on the page
  var tip = null;
  function showTip(e) {
    var t = e.target.closest && e.target.closest("[data-tip]");
    if (!t) { if (tip) tip.hidden = true; return; }
    if (!tip) { tip = document.createElement("div"); tip.className = "chart-tip"; tip.setAttribute("role", "status"); document.body.appendChild(tip); }
    tip.textContent = t.getAttribute("data-tip");
    tip.hidden = false;
    var x = Math.min(window.innerWidth - tip.offsetWidth - 8, Math.max(8, e.clientX - tip.offsetWidth / 2));
    tip.style.left = x + window.scrollX + "px";
    tip.style.top = (e.clientY + window.scrollY - tip.offsetHeight - 14) + "px";
  }
  document.addEventListener("pointermove", showTip);
  document.addEventListener("pointerdown", showTip);
  document.addEventListener("scroll", function () { if (tip) tip.hidden = true; }, { passive: true });

  /* ---- Data: reference tables + everyone's MOT position ---- */
  var cache = null;

  async function loadAll() {
    if (cache) return cache;
    if (!db) throw new Error("The database library didn't load – check the connection.");

    // First visit of the day: bring the demo dates up to today (quick no-op otherwise)
    await db.rpc("roll_clock");

    var results = await Promise.all([
      db.from("regions").select("*").order("sort"),
      db.from("bases").select("*").order("sort"),
      db.from("roles").select("*").order("sort"),
      db.from("people").select("*").order("sort"),
      db.from("rules").select("*"),
      db.from("mot_centres").select("*").eq("active", true).order("name"),
      db.from("vehicle_mot").select("*").order("registration"),
      db.from("vehicle_mileage").select("*"),
      db.from("mileage_weekly").select("*").order("week_start"),
      db.from("mileage_weekday").select("*"),
      db.from("vehicle_service").select("*"),
      db.from("service_providers").select("*").eq("active", true).order("name"),
      // Passes only (for the compliance trend); far fewer than the 1,000-row limit
      db.from("mot_tests").select("vehicle_id,test_date,expiry_date").eq("result", "Pass"),
      // Fire extinguishers and defibs (08_equipment.sql) – optional, so the app still works before it's run
      db.from("vehicle_equipment").select("*")
    ]);
    for (var i = 0; i < results.length - 1; i++) if (results[i].error) throw results[i].error;

    var c = {
      regions: results[0].data, bases: results[1].data, roles: results[2].data,
      people: results[3].data, centres: results[5].data, vehicles: results[6].data,
      rules: {}
    };
    results[4].data.forEach(function (r) { c.rules[r.key] = r; });
    // Mileage joins onto each vehicle (zeros if a van has no readings yet)
    var mil = new Map(results[7].data.map(function (r) { return [r.vehicle_id, r]; }));
    c.vehicles.forEach(function (v) {
      var r = mil.get(v.id) || {};
      v.odometer = r.odometer == null ? null : r.odometer;
      v.miles_7 = r.miles_7 || 0; v.miles_30 = r.miles_30 || 0; v.miles_365 = r.miles_365 || 0;
      v.days_used_30 = r.days_used_30 || 0;
    });
    // Service position joins onto each vehicle as v.svc
    var svc = new Map(results[10].data.map(function (r) { return [r.vehicle_id, r]; }));
    c.vehicles.forEach(function (v) { v.svc = svc.get(v.id) || { status: "OK", booked: false }; });
    c.providers = results[11].data;
    c.passes = results[12].data;
    // Equipment position joins onto each vehicle as v.eq.fire / v.eq.defib
    var eq = new Map();
    (results[13].error ? [] : results[13].data).forEach(function (r) {
      if (!eq.has(r.vehicle_id)) eq.set(r.vehicle_id, {});
      eq.get(r.vehicle_id)[r.kind] = r;
    });
    c.hasEquipment = !results[13].error;
    c.vehicles.forEach(function (v) { v.eq = eq.get(v.id) || {}; });
    c.weekly = results[8].data;
    c.weekday = results[9].data;
    c.regionById = new Map(c.regions.map(function (r) { return [r.id, r]; }));
    c.baseById = new Map(c.bases.map(function (b) { return [b.id, b]; }));
    c.roleByKey = new Map(c.roles.map(function (r) { return [r.key, r]; }));
    c.vehicleByReg = new Map(c.vehicles.map(function (v) { return [v.registration, v]; }));
    cache = c;
    return c;
  }

  function invalidate() { cache = null; }

  /* Who's signed in, with their role and the slice of the company they look after */
  function me(c) {
    var code = load(AS_KEY);
    var person = c.people.find(function (p) { return p.code === code; });
    if (!person) return null;
    var role = c.roleByKey.get(person.role_key);
    var scope = { level: role.scope, regionId: person.region_id, baseId: person.base_id };
    if (role.scope === "self") scope.level = "base";             // crew see their own base
    return { person: person, role: role, scope: scope };
  }

  function requireMe(c) {
    var m = me(c);
    if (!m) { location.replace("index.html"); throw new Error("Not signed in"); }
    return m;
  }

  function signOut() { save(AS_KEY, null); location.href = "index.html"; }

  /* ---- Header: "Signed in as …" and extra ⋮ menu rows ---- */
  function showWho(m) {
    var el = document.getElementById("who");
    if (!el || !m) return;
    el.textContent = m.role.label;          // the page heading already says where
    el.hidden = false;
  }

  function addMenuRows() {
    var panel = document.querySelector(".settings__panel");
    if (!panel) { setTimeout(addMenuRows, 50); return; }
    if (panel.querySelector("[data-nb]")) return;

    var sw = document.createElement("a");
    sw.className = "settings__link settings__row";
    sw.href = "index.html";
    sw.dataset.nb = "switch";
    sw.textContent = "Switch user";
    sw.addEventListener("click", function (e) { e.preventDefault(); signOut(); });
    panel.appendChild(sw);

    var reset = document.createElement("button");
    reset.type = "button";
    reset.className = "settings__link settings__row";
    reset.dataset.nb = "reset";
    reset.innerHTML = 'Reset demo <span class="settings__value">start again</span>';
    reset.addEventListener("click", async function () {
      if (!db) return;
      reset.disabled = true;
      reset.querySelector(".settings__value").textContent = "resetting…";
      var res = await db.rpc("reset_demo");
      reset.querySelector(".settings__value").textContent = res.error ? "failed" : "done";
      invalidate();
      setTimeout(function () { location.reload(); }, 400);
    });
    panel.appendChild(reset);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", addMenuRows);
  else addMenuRows();

  /* ---- Dates people type: 9/11/2027, 09/11/27, 9.11.2027, 9 11 2027, 9 Nov 2027 ----
     Returns "2027-11-09", "" for empty, or null when it isn't a real date. */
  var MONTH_WORDS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  function parseTyped(text) {
    var t = String(text || "").trim().toLowerCase();
    if (!t) return "";
    var p = t.split(/[\s\/.\-,]+/).filter(Boolean);
    if (p.length !== 3) return null;
    var d = parseInt(p[0], 10), mo = parseInt(p[1], 10), y = parseInt(p[2], 10);
    if (isNaN(mo)) mo = MONTH_WORDS.indexOf(p[1].slice(0, 3)) + 1;
    if (!/^\d+$/.test(p[0]) || !/^\d+$/.test(p[2]) || !(mo >= 1 && mo <= 12)) return null;
    if (p[2].length === 2) y += 2000;
    if (p[2].length !== 2 && p[2].length !== 4) return null;
    var dt = new Date(y, mo - 1, d);
    if (dt.getFullYear() !== y || dt.getMonth() !== mo - 1 || dt.getDate() !== d) return null;
    return y + "-" + String(mo).padStart(2, "0") + "-" + String(d).padStart(2, "0");
  }
  var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  // "Tue 9 Nov 2027" (year left off when it's this year and short is set)
  function fmtDay(s, short) {
    var d = parseDate(s);
    if (!d) return "–";
    var yr = short && d.getFullYear() === new Date().getFullYear() ? "" : " " + d.getFullYear();
    return DAY_NAMES[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()] + yr;
  }
  function toTyped(iso) { var d = parseDate(iso); return d ? String(d.getDate()).padStart(2, "0") + "/" + String(d.getMonth() + 1).padStart(2, "0") + "/" + d.getFullYear() : ""; }
  function daysBetween(a, b) { return Math.round((parseDate(b) - parseDate(a)) / 864e5); }

  /* ---- Side panel: opens over the page, Esc or × closes, focus goes back ---- */
  var openPanelEl = null;
  function openPanel(title, opts) {
    closePanel(true);
    opts = opts || {};
    var back = document.activeElement;
    var scrim = document.createElement("div");
    scrim.className = "panel-scrim";
    var panel = document.createElement("aside");
    panel.className = "panel";
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-modal", "true");
    panel.setAttribute("aria-label", title);
    panel.innerHTML = '<div class="panel__head"><h2>' + esc(title) + '</h2><span data-steps></span>' +
      '<button type="button" class="panel__close" aria-label="Close">×</button></div><div class="panel__content"></div>';
    panel.querySelector(".panel__content").style.cssText = "display:flex;flex-direction:column;flex:1;min-height:0";
    document.body.appendChild(scrim);
    document.body.appendChild(panel);
    document.body.classList.add("panel-open");
    function close() { closePanel(); }
    scrim.addEventListener("click", close);
    panel.querySelector(".panel__close").addEventListener("click", close);
    openPanelEl = { panel: panel, scrim: scrim, back: back, onClose: opts.onClose };
    return { el: panel.querySelector(".panel__content"), head: panel.querySelector("[data-steps]"), close: close };
  }
  function closePanel(silent) {
    if (!openPanelEl) return;
    var o = openPanelEl;
    openPanelEl = null;
    o.panel.remove(); o.scrim.remove();
    document.body.classList.remove("panel-open");
    if (o.back && o.back.focus && document.contains(o.back)) o.back.focus();
    if (!silent && o.onClose) o.onClose();
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && openPanelEl) {
      // Esc inside an open type-ahead list closes the list first
      if (e.target && e.target.getAttribute && e.target.getAttribute("aria-expanded") === "true") return;
      e.preventDefault(); closePanel();
    }
    // Keep Tab inside the panel
    if (e.key === "Tab" && openPanelEl) {
      var f = openPanelEl.panel.querySelectorAll('button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])');
      f = Array.prototype.filter.call(f, function (x) { return x.offsetParent !== null; });
      if (!f.length) return;
      var first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });

  /* ---- Line chart: one main series + an optional comparison (dashed) ---- */
  function lineChart(series, opts) {
    opts = opts || {};
    var W = opts.width || 480, H = opts.height || 170, L = 44, B = 24, T = 10, R = 10;
    var all = series.reduce(function (a, s) { return a.concat(s.values); }, []);
    var lo = opts.min != null ? opts.min : Math.min.apply(null, all), hi = opts.max != null ? opts.max : Math.max.apply(null, all);
    if (hi - lo < 1e-9) { hi = lo + 1; }
    var n = series[0].values.length;
    var x = function (i) { return L + (W - L - R) * (n === 1 ? 0.5 : i / (n - 1)); };
    var y = function (v) { return T + (H - T - B) * (1 - (v - lo) / (hi - lo)); };
    var out = '<svg class="chart" viewBox="0 0 ' + W + " " + H + '" role="img" aria-label="' + esc(opts.ariaLabel || "") + '">';
    [lo, (lo + hi) / 2, hi].forEach(function (v) {
      out += '<line class="chart__grid" x1="' + L + '" x2="' + (W - R) + '" y1="' + y(v) + '" y2="' + y(v) + '"/>' +
             '<text class="chart__axis" x="' + (L - 6) + '" y="' + (y(v) + 4) + '" text-anchor="end">' + esc(opts.fmt ? opts.fmt(v) : fmtNum(v)) + "</text>";
    });
    series.slice().reverse().forEach(function (s) {
      out += '<polyline class="chart__line' + (s.cmp ? " chart__line--cmp" : "") + '" points="' +
        s.values.map(function (v, i) { return x(i) + "," + y(v); }).join(" ") + '"/>';
    });
    var main = series[0].values;
    out += '<circle class="chart__dot" r="4" cx="' + x(n - 1) + '" cy="' + y(main[n - 1]) + '"/>';
    (opts.labels || []).forEach(function (lab, i) {
      if (i % (opts.labelEvery || 1) === 0 || i === n - 1)
        out += '<text class="chart__axis" x="' + x(i) + '" y="' + (H - 6) + '" text-anchor="middle">' + esc(lab) + "</text>";
      var w = (W - L - R) / Math.max(n - 1, 1);
      out += '<rect class="chart__hit" x="' + (x(i) - w / 2) + '" y="' + T + '" width="' + w + '" height="' + (H - T - B) +
        '" data-tip="' + esc((opts.tips && opts.tips[i]) || lab) + '"/>';
    });
    return out + "</svg>";
  }

  window.NB = {
    parseTyped: parseTyped, fmtDay: fmtDay, toTyped: toTyped, daysBetween: daysBetween,
    openPanel: openPanel, closePanel: closePanel, lineChart: lineChart,
    db: db, esc: esc, fmtDate: fmtDate, fmtDateTime: fmtDateTime, fmtNum: fmtNum, isoToday: isoToday,
    parseDate: parseDate, daysText: daysText, barChart: barChart, chartTable: chartTable, statusBadge: statusBadge, bookingBadge: bookingBadge,
    friendlyError: friendlyError, loadAll: loadAll, invalidate: invalidate,
    me: me, requireMe: requireMe, showWho: showWho, signOut: signOut,
    setAs: function (code) { save(AS_KEY, code); }
  };
})();
