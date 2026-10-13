/* =====================================================================
   dougs.js — shared behaviour for Doug's apps
   Adds the ⋮ settings menu to the app header and remembers each
   person's choices on that device.

   HOW TO USE: in every page's <head>, after dougs.css:
     <script src="dougs.js"></script>
   (Not "defer": it runs early so the saved theme applies before the
   page draws, avoiding a white flash in dark mode.)

   Settings:
     Theme      Follow device | Light | Dark
     Wallboard  large text that scales with the screen (for TVs)
     Wallboard  only if the page has <meta name="dougs-wallboard" content="on">
     Admin      only if the page has <meta name="dougs-admin" content="admin.html">

   A wallboard can also be set up by URL, which is then remembered:
     dashboard.html?theme=dark&wallboard=on
   ===================================================================== */

(function () {
  "use strict";

  var KEYS = { theme: "dougs.theme", wallboard: "dougs.wallboard" };
  var root = document.documentElement;

  /* ---- Storage (can fail in private browsing; never let that break a page) ---- */
  function load(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }
  function save(key, value) {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch (e) { /* settings just won't be remembered */ }
  }

  /* ---- Apply settings ---- */
  function applyTheme(mode) {
    if (mode === "light" || mode === "dark") root.setAttribute("data-theme", mode);
    else root.removeAttribute("data-theme");
  }
  function applyWallboard(on) {
    root.classList.toggle("wallboard", !!on);
  }

  function currentTheme() {
    var t = root.getAttribute("data-theme");
    return t === "light" || t === "dark" ? t : "auto";
  }

  /* ---- 1. Run immediately: URL settings win, then saved settings ---- */
  var params = new URLSearchParams(location.search);

  if (params.has("theme")) {
    var t = params.get("theme");
    save(KEYS.theme, t === "light" || t === "dark" ? t : null);
  }
  if (params.has("wallboard")) {
    var w = params.get("wallboard");
    save(KEYS.wallboard, w === "off" || w === "0" ? null : "on");
  }

  // A page can force a theme in its HTML (<html data-theme="dark">); respect that
  // unless the person has chosen otherwise.
  var savedTheme = load(KEYS.theme);
  if (savedTheme) applyTheme(savedTheme);

  // Wallboard size is only offered on pages that opt in:
  //   <meta name="dougs-wallboard" content="on">  (put it BEFORE the dougs.js line)
  var wallboardAllowed = !!document.querySelector('meta[name="dougs-wallboard"]') ||
                         root.classList.contains("wallboard");
  applyWallboard(wallboardAllowed &&
                 (load(KEYS.wallboard) === "on" || root.classList.contains("wallboard")));

  /* ---- 2. Build the ⋮ menu once the page has loaded ---- */
  var THEMES = [
    { value: "auto",  label: "Device" },
    { value: "light", label: "Light" },
    { value: "dark",  label: "Dark" }
  ];

  var DOTS_ICON =
    '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true" focusable="false">' +
    '<circle cx="12" cy="5" r="2.2" fill="currentColor"/>' +
    '<circle cx="12" cy="12" r="2.2" fill="currentColor"/>' +
    '<circle cx="12" cy="19" r="2.2" fill="currentColor"/></svg>';

  function buildMenu() {
    var header = document.querySelector(".app-header__inner");
    if (!header || header.querySelector(".settings")) return;

    var wrap = document.createElement("div");
    wrap.className = "settings";

    var button = document.createElement("button");
    button.type = "button";
    button.className = "settings__button";
    button.setAttribute("aria-label", "Settings");
    button.setAttribute("aria-haspopup", "true");
    button.setAttribute("aria-expanded", "false");
    button.setAttribute("aria-controls", "settings-panel");
    button.innerHTML = DOTS_ICON;

    var panel = document.createElement("div");
    panel.className = "settings__panel";
    panel.id = "settings-panel";
    panel.hidden = true;

    // ---- Theme: a row showing the current choice; tap to show the options ----
    var themeRow = document.createElement("button");
    themeRow.type = "button";
    themeRow.className = "settings__link settings__row";
    themeRow.setAttribute("aria-expanded", "false");
    themeRow.setAttribute("aria-controls", "settings-theme-options");
    themeRow.innerHTML = 'Theme <span class="settings__value"></span>';

    var themeOptions = document.createElement("div");
    themeOptions.className = "settings__options";
    themeOptions.id = "settings-theme-options";
    themeOptions.hidden = true;

    var choices = document.createElement("div");
    choices.setAttribute("role", "radiogroup");
    choices.setAttribute("aria-label", "Theme");

    THEMES.forEach(function (option) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "settings__choice";
      b.setAttribute("role", "radio");
      b.textContent = option.label;
      b.dataset.theme = option.value;
      b.addEventListener("click", function () {
        applyTheme(option.value);
        save(KEYS.theme, option.value === "auto" ? null : option.value);
        sync();
      });
      choices.appendChild(b);
    });
    themeOptions.appendChild(choices);

    themeRow.addEventListener("click", function () {
      var show = themeOptions.hidden;
      themeOptions.hidden = !show;
      themeRow.setAttribute("aria-expanded", String(show));
    });

    panel.appendChild(themeRow);
    panel.appendChild(themeOptions);

    // ---- Wallboard size: only on pages that opt in ----
    var wbInput = null;
    if (wallboardAllowed) {
      var wbRow = document.createElement("label");
      wbRow.className = "settings__link settings__row settings__check-row";
      wbRow.innerHTML = 'Wallboard size <input type="checkbox" id="settings-wallboard">';
      panel.appendChild(wbRow);
      wbInput = wbRow.querySelector("input");
      wbInput.addEventListener("change", function () {
        applyWallboard(wbInput.checked);
        save(KEYS.wallboard, wbInput.checked ? "on" : null);
      });
    }

    // ---- Admin link: only on pages that opt in ----
    var adminMeta = document.querySelector('meta[name="dougs-admin"]');
    if (adminMeta && adminMeta.content) {
      var adminLink = document.createElement("a");
      adminLink.className = "settings__link settings__row";
      adminLink.href = adminMeta.content;
      adminLink.textContent = "Admin";
      panel.appendChild(adminLink);
    }

    wrap.appendChild(button);
    wrap.appendChild(panel);
    header.appendChild(wrap);

    var THEME_NAMES = { auto: "Device", light: "Light", dark: "Dark" };

    function sync() {
      var mode = currentTheme();
      choices.querySelectorAll("button").forEach(function (b) {
        b.setAttribute("aria-checked", String(b.dataset.theme === mode));
      });
      themeRow.querySelector(".settings__value").textContent = THEME_NAMES[mode];
      if (wbInput) wbInput.checked = root.classList.contains("wallboard");
    }

    function open() {
      sync();
      themeOptions.hidden = true;
      themeRow.setAttribute("aria-expanded", "false");
      panel.hidden = false;
      button.setAttribute("aria-expanded", "true");
      themeRow.focus();
    }
    function close(returnFocus) {
      if (panel.hidden) return;
      panel.hidden = true;
      button.setAttribute("aria-expanded", "false");
      if (returnFocus) button.focus();
    }

    button.addEventListener("click", function () {
      if (panel.hidden) open(); else close(false);
    });

    document.addEventListener("click", function (event) {
      if (!wrap.contains(event.target)) close(false);
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") close(true);
    });

    sync();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", buildMenu);
  } else {
    buildMenu();
  }

  /* Small public hook, e.g. for a page that wants to read the theme */
  window.Dougs = { theme: currentTheme };
})();
