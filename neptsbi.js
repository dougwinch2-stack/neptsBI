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
    if (row.status === "OK") return "";
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
      db.from("vehicle_mot").select("*").order("registration")
    ]);
    for (var i = 0; i < results.length; i++) if (results[i].error) throw results[i].error;

    var c = {
      regions: results[0].data, bases: results[1].data, roles: results[2].data,
      people: results[3].data, centres: results[5].data, vehicles: results[6].data,
      rules: {}
    };
    results[4].data.forEach(function (r) { c.rules[r.key] = r; });
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
    var where = m.person.base_id ? "" : "";
    el.innerHTML = 'Signed in as <strong>' + esc(m.person.name) + "</strong>" + where;
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

  window.NB = {
    db: db, esc: esc, fmtDate: fmtDate, fmtDateTime: fmtDateTime, fmtNum: fmtNum, isoToday: isoToday,
    parseDate: parseDate, daysText: daysText, statusBadge: statusBadge, bookingBadge: bookingBadge,
    friendlyError: friendlyError, loadAll: loadAll, invalidate: invalidate,
    me: me, requireMe: requireMe, showWho: showWho, signOut: signOut,
    setAs: function (code) { save(AS_KEY, code); }
  };
})();
