/*
 * Insta rules. Injected at document start, main frame only.
 * forMainFrameOnly is set on the native WKUserScript (true) so captcha and
 * login iframes are not redirected.
 *
 * Idempotent: a window flag guards a second injection in the same document.
 * history.replaceState does not fire popstate, so pushState and replaceState
 * are wrapped. The wrapper skips itself while restoring a reel URL.
 *
 * iOS WebKit: preventDefault on touchmove works only when the listener is
 * registered with { passive: false }. touch-action and overscroll-behavior
 * are supported on iOS 16+.
 *
 * Selectors below are assumptions. Comments say what each one targets.
 * Do not remove React nodes. Hide them.
 */
(function () {
  "use strict";

  if (window.__INSTA_BOOTED__) {
    try {
      if (window.__INSTA_CONFIG && window.__instaApplyConfig) {
        window.__instaApplyConfig(window.__INSTA_CONFIG);
      }
    } catch (e) {}
    return;
  }
  window.__INSTA_BOOTED__ = true;

  // KEEP IN SYNC with PathPolicy.safetyAllowPatterns.
  var SAFETY_FALLBACK = [
    "^/accounts(?:/.*)?$",
    "^/challenge(?:/.*)?$",
    "^/consent(?:/.*)?$",
    "^/direct(?:/.*)?$",
    "^/stories(?:/.*)?$",
    "^/emails(?:/.*)?$",
    "^/legal(?:/.*)?$",
    "^/privacy(?:/.*)?$",
    "^/terms(?:/.*)?$",
    "^/about(?:/.*)?$",
    "^/oauth(?:/.*)?$",
    "^/reel/[^/]+$",
    "^/[^/]+/reel/[^/]+$",
    "^/p/[^/]+$"
  ];

  var PERMANENT_EVENTS = ["click", "pointerdown", "pointerup", "touchstart", "touchend", "auxclick"];

  var config = window.__INSTA_CONFIG || {};
  var enabled = window.__INSTA_ENABLED !== false;
  var regexCache = Object.create(null);
  var redirectArmed = false;
  var restoring = false;
  var didClear = false;
  var soonTimer = null;
  var slowTimer = null;
  var originalPush = null;
  var originalReplace = null;

  var lock = {
    active: false,
    reelId: null,
    url: null,
    root: null,
    styledRoot: null,
    prevOverflow: "",
    prevOverscroll: "",
    prevTouchAction: "",
    listeners: [],
    sx: 0,
    sy: 0,
    tracking: false
  };

  window.__instaApplyConfig = function (next) {
    try {
      if (!next || typeof next !== "object") return;
      window.__INSTA_CONFIG = next;
      config = next;
      regexCache = Object.create(null);
      redirectArmed = false;
      didClear = false;
      rebuildStyle();
      onRoute();
    } catch (e) {}
  };

  window.__instaSetEnabled = function (on) {
    try {
      enabled = !!on;
      window.__INSTA_ENABLED = enabled;
      didClear = false;
      redirectArmed = false;
      onRoute();
    } catch (e) {}
  };

  try {
    boot();
  } catch (bootError) {}

  function boot() {
    maybeRedirect();
    installHistoryHooks();
    installPermanentInterceptor();
    installObserver();
    setInterval(function () {
      scheduleSlow();
    }, 1500);
    onRoute();
    try {
      postLog("rules " + ((config && config.configVersion) || "?"));
    } catch (e) {}
  }

  function onRoute() {
    try {
      if (!enabled) {
        if (!didClear) {
          clearMarks();
          rebuildStyle();
          releaseLock(true);
          didClear = true;
        }
        return;
      }
      didClear = false;
      if (!isInstagramPage()) return;
      maybeRedirect();
      updateHtmlClasses();
      rebuildStyle();
      applyDomRules();
      syncReelLock();
    } catch (e) {}
  }

  function scheduleSoon() {
    if (soonTimer !== null) return;
    soonTimer = setTimeout(function () {
      soonTimer = null;
      onRoute();
    }, 0);
  }

  function scheduleSlow() {
    if (slowTimer !== null) return;
    slowTimer = setTimeout(function () {
      slowTimer = null;
      onRoute();
    }, 250);
  }

  function isInstagramPage() {
    try {
      if (location.protocol !== "http:" && location.protocol !== "https:") return false;
      var host = (location.hostname || "").toLowerCase();
      return host === "instagram.com" || endsWith(host, ".instagram.com");
    } catch (e) {
      return false;
    }
  }

  function endsWith(text, suffix) {
    if (!text || text.length < suffix.length) return false;
    return text.slice(text.length - suffix.length) === suffix;
  }

  function normalizePath(pathname) {
    var p = pathname || "/";
    var hash = p.indexOf("#");
    if (hash !== -1) p = p.slice(0, hash);
    var query = p.indexOf("?");
    if (query !== -1) p = p.slice(0, query);
    if (!p) return "/";
    if (p.charAt(0) !== "/") p = "/" + p;
    while (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.slice(0, -1);
    return p;
  }

  function getRegex(pattern) {
    if (!pattern || typeof pattern !== "string") return null;
    if (Object.prototype.hasOwnProperty.call(regexCache, pattern)) return regexCache[pattern];
    var compiled = null;
    try {
      compiled = new RegExp(pattern);
    } catch (e) {
      compiled = null;
    }
    regexCache[pattern] = compiled;
    return compiled;
  }

  function matches(pattern, path) {
    var re = getRegex(pattern);
    if (!re) return false;
    var found = re.exec(path);
    return !!(found && found[0] === path);
  }

  function matchesAny(patterns, path) {
    if (!Array.isArray(patterns)) return false;
    var i;
    for (i = 0; i < patterns.length; i++) {
      if (matches(patterns[i], path)) return true;
    }
    return false;
  }

  function safetyPatterns() {
    var fromConfig = config && config.safetyAllowPaths;
    if (Array.isArray(fromConfig) && fromConfig.length > 0) return fromConfig;
    return SAFETY_FALLBACK;
  }

  function allowPatterns() {
    var reels = config.reels || {};
    var explore = config.explore || {};
    var patterns = [];
    var safety = safetyPatterns();
    var i;
    for (i = 0; i < safety.length; i++) patterns.push(safety[i]);
    if (Array.isArray(config.allowedPaths)) {
      for (i = 0; i < config.allowedPaths.length; i++) patterns.push(config.allowedPaths[i]);
    }
    if (reels.allowReelPathPattern) patterns.push(reels.allowReelPathPattern);
    if (reels.allowUserReelPathPattern) patterns.push(reels.allowUserReelPathPattern);
    if (reels.postPathPattern) patterns.push(reels.postPathPattern);
    if (reels.allowIdPaths !== false && reels.idPathPattern) patterns.push(reels.idPathPattern);
    var mode = explore.mode || "hideGridKeepSearch";
    if (mode !== "blockAll" && Array.isArray(explore.alwaysAllowPathPatterns)) {
      for (i = 0; i < explore.alwaysAllowPathPatterns.length; i++) patterns.push(explore.alwaysAllowPathPatterns[i]);
    }
    if (reels.allowIdPaths === false && reels.idPathPattern) {
      var withoutId = [];
      for (i = 0; i < patterns.length; i++) {
        if (patterns[i] !== reels.idPathPattern) withoutId.push(patterns[i]);
      }
      patterns = withoutId;
    }
    if (mode === "blockAll" && Array.isArray(explore.alwaysAllowPathPatterns)) {
      var banned = explore.alwaysAllowPathPatterns;
      var kept = [];
      for (i = 0; i < patterns.length; i++) {
        if (banned.indexOf(patterns[i]) === -1) kept.push(patterns[i]);
      }
      patterns = kept;
    }
    return patterns;
  }

  function classify(pathname) {
    var path = normalizePath(pathname);
    var reels = config.reels || {};
    var explore = config.explore || {};
    var profile = config.profile || {};
    if (path === redirectTarget()) return "allow";
    var feedPattern = reels.feedPathPattern || "^/reels$";
    if (reels.blockFeed !== false && matches(feedPattern, path)) return "block";
    var idPattern = reels.idPathPattern || "^/reels/[^/]+$";
    if (reels.allowIdPaths === false && matches(idPattern, path)) return "block";
    if (matchesAny(allowPatterns(), path)) return "allow";
    var tabPattern = profile.reelsTabPathPattern || "^/[^/]+/reels$";
    if (profile.hideReelsTab !== false && matches(tabPattern, path)) return "block";
    var browse = explore.blockBrowsePathPatterns;
    if (!Array.isArray(browse)) {
      browse = ["^/explore/tags(?:/.*)?$", "^/explore/locations(?:/.*)?$"];
    }
    if (matchesAny(browse, path)) return "block";
    var mode = explore.mode || "hideGridKeepSearch";
    if (mode === "blockAll" && matchesAny(explore.alwaysAllowPathPatterns, path)) return "block";
    if (matchesAny(config.blockedPaths, path)) return "block";
    return "allow";
  }

  function redirectTarget() {
    var raw = (config.redirect && config.redirect.targetPath) || "/";
    var target = normalizePath(raw);
    var feedPattern = (config.reels && config.reels.feedPathPattern) || "^/reels$";
    if (matches(feedPattern, target)) return "/";
    if (!target || target.charAt(0) !== "/") return "/";
    return target;
  }

  function maybeRedirect() {
    if (!enabled || !isInstagramPage() || redirectArmed) return;
    if (classify(location.pathname) !== "block") return;
    if (!consumeBudget()) {
      showLoopBanner();
      return;
    }
    var target = redirectTarget();
    if (normalizePath(location.pathname) === target) return;
    redirectArmed = true;
    try {
      location.replace(target);
    } catch (e) {
      showLoopBanner();
    }
  }

  function redirectToTarget() {
    redirectArmed = false;
    maybeRedirect();
  }

  function consumeBudget() {
    var redirect = config.redirect || {};
    var max = Number(redirect.maxRedirects);
    var windowMs = Number(redirect.windowMs);
    if (!isFinite(max) || max < 1) max = 6;
    if (!isFinite(windowMs) || windowMs < 500) windowMs = 10000;
    var now = Date.now();
    var stamps = [];
    try {
      var raw = sessionStorage.getItem("insta.redirectBudget.v1");
      var parsed = raw ? JSON.parse(raw) : [];
      if (Array.isArray(parsed)) stamps = parsed;
    } catch (e) {
      stamps = [];
    }
    var fresh = [];
    var i;
    for (i = 0; i < stamps.length; i++) {
      if (typeof stamps[i] === "number" && now - stamps[i] < windowMs) fresh.push(stamps[i]);
    }
    if (fresh.length >= max) return false;
    fresh.push(now);
    try {
      sessionStorage.setItem("insta.redirectBudget.v1", JSON.stringify(fresh));
    } catch (e) {}
    return true;
  }

  function showLoopBanner() {
    if (document.getElementById("insta-loop-banner")) return;
    var banner = document.createElement("div");
    banner.id = "insta-loop-banner";
    banner.setAttribute("role", "alert");
    banner.style.cssText = "position:fixed;z-index:2147483647;left:12px;right:12px;bottom:24px;padding:12px 14px;background:#111;color:#fff;font:14px -apple-system,BlinkMacSystemFont,sans-serif;border-radius:12px;";
    banner.appendChild(document.createTextNode("Insta paused redirects to avoid a loop. "));
    var button = document.createElement("button");
    button.type = "button";
    button.textContent = "Go home";
    button.style.cssText = "margin-left:8px;color:#111;background:#fff;border:0;border-radius:8px;padding:6px 10px;";
    button.addEventListener("click", function () {
      try {
        sessionStorage.removeItem("insta.redirectBudget.v1");
      } catch (e) {}
      redirectArmed = true;
      location.replace("/");
    });
    banner.appendChild(button);
    (document.body || document.documentElement).appendChild(banner);
  }

  function installHistoryHooks() {
    originalPush = history.pushState;
    originalReplace = history.replaceState;
    history.pushState = function () {
      var result = originalPush.apply(history, arguments);
      if (!restoring) {
        try {
          maybeRedirect();
        } catch (e) {}
        scheduleSoon();
      }
      return result;
    };
    history.replaceState = function () {
      var result = originalReplace.apply(history, arguments);
      if (restoring) return result;
      try {
        maybeRedirect();
      } catch (e) {}
      scheduleSoon();
      return result;
    };
    window.addEventListener("popstate", function () {
      try {
        maybeRedirect();
      } catch (e) {}
      scheduleSoon();
    });
    window.addEventListener("hashchange", function () {
      try {
        maybeRedirect();
      } catch (e) {}
      scheduleSoon();
    });
  }

  function installObserver() {
    if (!document.documentElement || !window.MutationObserver) return;
    var observer = new MutationObserver(function () {
      scheduleSlow();
    });
    try {
      observer.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
  }

  function installPermanentInterceptor() {
    var i;
    for (i = 0; i < PERMANENT_EVENTS.length; i++) {
      document.addEventListener(PERMANENT_EVENTS[i], onIntercept, { capture: true, passive: false });
    }
  }

  function eventEnabled(type) {
    var list = config.reelsNav && config.reelsNav.interceptEvents;
    if (!Array.isArray(list) || list.length === 0) return true;
    var i;
    for (i = 0; i < list.length; i++) {
      if (list[i] === type) return true;
    }
    return false;
  }

  function onIntercept(event) {
    if (!enabled || !isInstagramPage()) return;
    if (!eventEnabled(event.type)) return;
    try {
      var anchor = anchorFromEvent(event);
      if (anchor) {
        var anchorPath = pathFromHref(anchor.getAttribute("href"));
        if (anchorPath && isProfileReelsPath(anchorPath) && (!config.profile || config.profile.hideReelsTab !== false)) {
          event.preventDefault();
          event.stopImmediatePropagation();
          redirectToTarget();
          return;
        }
      }
      if (hitsReelsNav(event)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        return;
      }
      if (anchor) {
        var blockedPath = pathFromHref(anchor.getAttribute("href"));
        if (blockedPath && classify(blockedPath) === "block") {
          event.preventDefault();
          event.stopImmediatePropagation();
          redirectToTarget();
        }
      }
    } catch (e) {}
  }

  function pathFromHref(href) {
    if (!href || href.indexOf("javascript:") === 0 || href.indexOf("mailto:") === 0) return null;
    try {
      var url = new URL(href, location.origin);
      if (url.origin !== location.origin) return null;
      return normalizePath(url.pathname);
    } catch (e) {
      return null;
    }
  }

  function anchorFromEvent(event) {
    var nodes = event.composedPath ? event.composedPath() : [];
    var i;
    for (i = 0; i < nodes.length; i++) {
      if (nodes[i] && nodes[i].tagName === "A") return nodes[i];
    }
    var target = event.target;
    if (target && target.closest) return target.closest("a");
    return null;
  }

  function isProfileReelsPath(path) {
    var pattern = (config.profile && config.profile.reelsTabPathPattern) || "^/[^/]+/reels$";
    return matches(pattern, path);
  }

  function isReelsFeedPath(path) {
    var pattern = (config.reels && config.reels.feedPathPattern) || "^/reels$";
    return matches(pattern, normalizePath(path));
  }

  function isHomePath() {
    var home = normalizePath((config.feed && config.feed.homePath) || "/");
    return normalizePath(location.pathname) === home;
  }

  function isExploreKeepPage() {
    var explore = config.explore || {};
    if ((explore.mode || "hideGridKeepSearch") === "blockAll") return false;
    return matchesAny(explore.alwaysAllowPathPatterns, normalizePath(location.pathname));
  }

  function updateHtmlClasses() {
    var root = document.documentElement;
    if (!root) return;
    setClass(root, "insta-home", isHomePath());
    setClass(root, "insta-explore", isExploreKeepPage());
    setClass(root, "insta-reels-hidden", !!(config.reelsNav && config.reelsNav.mode === "hidden"));
  }

  function setClass(el, name, on) {
    if (!el || !el.classList) return;
    var has = el.classList.contains(name);
    if (on && !has) el.classList.add(name);
    if (!on && has) el.classList.remove(name);
  }

  function clampOpacity(value) {
    var number = Number(value);
    if (!isFinite(number) || number < 0 || number > 1) return 0.4;
    return number;
  }

  function rebuildStyle() {
    var css = "";
    if (enabled) css = buildCSS();
    var style = document.getElementById("insta-rules-style");
    if (!style) {
      style = document.createElement("style");
      style.id = "insta-rules-style";
      (document.head || document.documentElement).appendChild(style);
    }
    if (style.textContent !== css) style.textContent = css;
  }

  function buildCSS() {
    var opacity = clampOpacity(config.reelsNav && config.reelsNav.dimOpacity);
    var css = "";
    css += ":root{--insta-reels-opacity:" + opacity + ";}\n";
    /*
     * article under html.insta-home:
     * targets feed posts (Instagram wraps a post in <article>).
     * must not match the stories tray when that tray is not an article.
     * failure: if posts are no longer articles, the feed stays visible;
     * if the tray is an article, .insta-stories-keep has to unhide it.
     * Scoped to html.insta-home so profile grids and DMs are untouched.
     */
    css += "html.insta-home article,html.insta-home [data-insta-hide='1']{display:none !important;height:0 !important;max-height:0 !important;margin:0 !important;padding:0 !important;overflow:hidden !important;visibility:hidden !important;pointer-events:none !important;}\n";
    css += "html.insta-home .insta-stories-keep,html.insta-home .insta-stories-keep article{display:flex !important;height:auto !important;max-height:none !important;margin:revert !important;padding:revert !important;overflow:visible !important;visibility:visible !important;pointer-events:auto !important;}\n";
    var hides = safeSelectors(config.feed && config.feed.hideSelectors);
    var h;
    for (h = 0; h < hides.length; h++) {
      if (hides[h] === "article") continue;
      css += "html.insta-home " + hides[h] + "{display:none !important;height:0 !important;max-height:0 !important;overflow:hidden !important;visibility:hidden !important;pointer-events:none !important;}\n";
    }
    /*
     * Reels nav dim. No pointer-events:none — taps would fall through.
     * The capture interceptor calls preventDefault instead.
     */
    css += "[data-insta-reels-nav='1']{opacity:var(--insta-reels-opacity) !important;-webkit-touch-callout:none !important;}\n";
    css += "html.insta-reels-hidden [data-insta-reels-nav='1']{visibility:hidden !important;}\n";
    css += "html.insta-explore [data-insta-explore-hide='1']{display:none !important;}\n";
    css += "[data-insta-explore-nav='1']{display:none !important;}\n";
    css += "[data-insta-profile-reels='1']{display:none !important;}\n";
    css += "[data-insta-reel-next='1']{visibility:hidden !important;}\n";
    css += "[data-insta-locked='1']{overflow:hidden !important;overscroll-behavior:none !important;touch-action:none !important;}\n";
    var allows = safeSelectors(config.reelLock && config.reelLock.allowScrollSelectors);
    var a;
    for (a = 0; a < allows.length; a++) {
      css += "[data-insta-locked='1'] " + allows[a] + "{touch-action:pan-y !important;overflow:auto !important;}\n";
    }
    return css;
  }

  function safeSelectors(list) {
    if (!Array.isArray(list)) return [];
    var out = [];
    var i;
    for (i = 0; i < list.length; i++) {
      var selector = list[i];
      if (typeof selector !== "string") continue;
      if (!selector || selector.length > 300) continue;
      if (/[{}<>]|expression\s*\(|url\s*\(|@import|\/\*/i.test(selector)) continue;
      try {
        document.querySelector(selector);
        out.push(selector);
      } catch (e) {}
    }
    return out;
  }

  function applyDomRules() {
    if (!isInstagramPage()) return;
    if (isHomePath()) {
      markStories();
      markStoryArticles();
      markFeedArticles();
      hideTextSnippets();
    }
    decorateReelsNav();
    decorateProfileReelsTabs();
    applyExplore();
  }

  function markStories() {
    var selectors = safeSelectors(config.feed && config.feed.storiesSelectors);
    if (selectors.length === 0) selectors = ["a[href*='/stories/']"];
    var depth = Number(config.feed && config.feed.storiesTrayAncestorDepth);
    if (!isFinite(depth) || depth < 1) depth = 4;
    if (depth > 8) depth = 8;
    var links = [];
    var s;
    var i;
    for (s = 0; s < selectors.length; s++) {
      var found;
      try {
        found = document.querySelectorAll(selectors[s]);
      } catch (e) {
        continue;
      }
      for (i = 0; i < found.length; i++) links.push(found[i]);
    }
    for (i = 0; i < links.length; i++) {
      var tray = ancestorTray(links[i], depth);
      if (tray && !tray.classList.contains("insta-stories-keep")) tray.classList.add("insta-stories-keep");
    }
  }

  /*
   * Story links: a[href*='/stories/'] (assumption).
   * Targets the horizontal tray. Must not match main, or the keep rule
   * unhides the feed. Failure: stories hrefs change, so the tray stays hidden
   * with the posts. Lower storiesTrayAncestorDepth if the keep region is too big.
   */
  function ancestorTray(el, depth) {
    var node = el;
    var best = el.parentElement || el;
    var steps;
    for (steps = 0; steps < depth && node && node.parentElement; steps++) {
      node = node.parentElement;
      if (!node || node === document.body || node === document.documentElement) break;
      if (node.tagName === "MAIN" || node.getAttribute("role") === "main" || node.tagName === "NAV") break;
      if (wrapsFeed(node)) break;
      best = node;
      var count = 0;
      try {
        count = node.querySelectorAll("a[href*='/stories/']").length;
      } catch (e) {
        count = 0;
      }
      if (count >= 2) break;
    }
    if (!best || best === document.body || best === document.documentElement) return null;
    if (best.tagName === "MAIN" || best.getAttribute("role") === "main") return null;
    if (wrapsFeed(best)) return null;
    return best;
  }

  function wrapsFeed(node) {
    var articles;
    try {
      articles = node.querySelectorAll("article");
    } catch (e) {
      return false;
    }
    var i;
    for (i = 0; i < articles.length; i++) {
      if (!articles[i].querySelector("a[href*='/stories/']")) return true;
    }
    return false;
  }

  function markStoryArticles() {
    var articles = document.querySelectorAll("article");
    var i;
    for (i = 0; i < articles.length; i++) {
      var article = articles[i];
      if (article.querySelector("a[href*='/stories/']") && !article.querySelector("time") && !wrapsFeed(article)) {
        if (!article.classList.contains("insta-stories-keep")) article.classList.add("insta-stories-keep");
      }
    }
  }

  function markFeedArticles() {
    var articles = document.querySelectorAll("article");
    var i;
    for (i = 0; i < articles.length; i++) {
      var article = articles[i];
      if (article.closest(".insta-stories-keep")) continue;
      if (matchesKeep(article)) continue;
      if (article.getAttribute("data-insta-hide") !== "1") article.setAttribute("data-insta-hide", "1");
    }
  }

  function matchesKeep(el) {
    var keeps = safeSelectors(config.feed && config.feed.keepSelectors);
    var i;
    for (i = 0; i < keeps.length; i++) {
      try {
        if (el.matches(keeps[i]) || (el.closest && el.closest(keeps[i]))) return true;
      } catch (e) {}
    }
    return false;
  }

  /*
   * Text snippets are assumptions for blocks that are not <article>:
   * "Suggested for you", "You're all caught up", "Suggested accounts".
   * Must not match the stories tray or nav. Failure: copy changes and the
   * block remains; edit hideTextSnippets.
   */
  function hideTextSnippets() {
    var snippets = (config.feed && config.feed.hideTextSnippets) || [];
    if (!Array.isArray(snippets) || snippets.length === 0) return;
    var nodes = document.querySelectorAll("h1, h2, h3, span, p");
    var cap = nodes.length > 700 ? 700 : nodes.length;
    var i;
    for (i = 0; i < cap; i++) {
      var text = ownText(nodes[i]);
      if (!text || text.length > 80) continue;
      var s;
      for (s = 0; s < snippets.length; s++) {
        if (snippets[s] && text.indexOf(snippets[s]) !== -1) {
          markSnippetHost(nodes[i]);
          break;
        }
      }
    }
  }

  function ownText(el) {
    var text = "";
    var i;
    for (i = 0; i < el.childNodes.length; i++) {
      var node = el.childNodes[i];
      if (node.nodeType === 3 && node.nodeValue) text += node.nodeValue;
    }
    return text.replace(/\s+/g, " ").trim();
  }

  function markSnippetHost(el) {
    var node = el;
    var depth;
    for (depth = 0; depth < 10 && node && node !== document.body; depth++) {
      if (node.classList && node.classList.contains("insta-stories-keep")) return;
      if (node.tagName === "NAV" || node.tagName === "HEADER") return;
      if (matchesKeep(node)) return;
      if (node.tagName === "ARTICLE" || node.tagName === "SECTION") {
        if (node.getAttribute("data-insta-hide") !== "1") node.setAttribute("data-insta-hide", "1");
        return;
      }
      node = node.parentElement;
    }
  }

  /*
   * Reels nav: anchors whose path is exactly /reels, or an aria-label that
   * equals labelMatchers ("Reels"), inside nav / tablist only.
   * Must not match /reel/<id>, /reels/<id>, profile /user/reels, Home, Search,
   * Create, or Profile. Failure: the control has no href and a new label,
   * so it stays clickable until labelMatchers is updated. The /reels redirect
   * still sends the feed home.
   */
  function findReelsNavNodes() {
    var roots = [];
    var rootSelectors = safeSelectors(config.reelsNav && config.reelsNav.navRootSelectors);
    if (rootSelectors.length === 0) rootSelectors = ["nav", "[role='tablist']"];
    var r;
    for (r = 0; r < rootSelectors.length; r++) {
      var list;
      try {
        list = document.querySelectorAll(rootSelectors[r]);
      } catch (e) {
        continue;
      }
      var n;
      for (n = 0; n < list.length; n++) roots.push(list[n]);
    }
    var found = [];
    var seen = [];
    function consider(el) {
      if (!el || seen.indexOf(el) !== -1) return;
      var href = el.getAttribute && el.getAttribute("href");
      var path = href ? pathFromHref(href) : null;
      if (path && isProfileReelsPath(path)) return;
      if (path && path !== "/reels") return;
      var labeled = isReelsLabeled(el);
      var exact = path === "/reels";
      if (!exact && !labeled) return;
      if (!exact && labeled && !insideNav(el)) return;
      seen.push(el);
      found.push(el);
    }
    var selectors = safeSelectors(config.reelsNav && config.reelsNav.selectors);
    var i;
    for (i = 0; i < roots.length; i++) {
      var s;
      for (s = 0; s < selectors.length; s++) {
        var nodes;
        try {
          nodes = roots[i].querySelectorAll(selectors[s]);
        } catch (e) {
          continue;
        }
        var j;
        for (j = 0; j < nodes.length; j++) consider(nodes[j]);
      }
      var labeledNodes;
      try {
        labeledNodes = roots[i].querySelectorAll("[aria-label]");
      } catch (e) {
        labeledNodes = [];
      }
      var k;
      for (k = 0; k < labeledNodes.length; k++) {
        if (isReelsLabeled(labeledNodes[k])) consider(labeledNodes[k]);
      }
    }
    return found;
  }

  function isReelsLabeled(el) {
    if (!el || !el.getAttribute) return false;
    var label = el.getAttribute("aria-label") || "";
    var matchers = (config.reelsNav && config.reelsNav.labelMatchers) || ["Reels"];
    var i;
    for (i = 0; i < matchers.length; i++) {
      if (label === matchers[i]) return true;
    }
    return false;
  }

  function insideNav(el) {
    return !!(el.closest && el.closest("nav, [role='tablist'], [role='navigation']"));
  }

  function decorateReelsNav() {
    var nodes = findReelsNavNodes();
    var i;
    for (i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.getAttribute("data-insta-reels-nav") !== "1") el.setAttribute("data-insta-reels-nav", "1");
      if (el.getAttribute("aria-disabled") !== "true") {
        el.setAttribute("aria-disabled", "true");
        el.setAttribute("data-insta-set-aria", "1");
      }
      if (el.getAttribute("tabindex") !== "-1") {
        el.setAttribute("tabindex", "-1");
        el.setAttribute("data-insta-set-tab", "1");
      }
    }
  }

  function hitsReelsNav(event) {
    var nodes = event.composedPath ? event.composedPath() : [];
    var i;
    for (i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el && el.getAttribute && el.getAttribute("data-insta-reels-nav") === "1") return true;
    }
    var target = event.target;
    if (target && target.closest && target.closest("[data-insta-reels-nav='1']")) return true;
    var live = findReelsNavNodes();
    for (i = 0; i < live.length; i++) {
      if (live[i] === target || (live[i].contains && target && live[i].contains(target))) return true;
    }
    return false;
  }

  /*
   * Profile Reels tab: href path matches ^/[^/]+/reels$ (assumption).
   * The candidate selector a[href$='/reels'] also matches the bottom /reels
   * link, so the path check is required. Must not match the bottom nav.
   * Failure: the tab is a button with no href. The path redirect still
   * catches /username/reels if Instagram navigates there.
   */
  function decorateProfileReelsTabs() {
    if (config.profile && config.profile.hideReelsTab === false) return;
    var selectors = safeSelectors(config.profile && config.profile.reelsTabSelectors);
    var i;
    for (i = 0; i < selectors.length; i++) {
      var nodes;
      try {
        nodes = document.querySelectorAll(selectors[i]);
      } catch (e) {
        continue;
      }
      var j;
      for (j = 0; j < nodes.length; j++) {
        var path = pathFromHref(nodes[j].getAttribute("href"));
        if (!path || !isProfileReelsPath(path)) continue;
        if (nodes[j].getAttribute("data-insta-profile-reels") !== "1") {
          nodes[j].setAttribute("data-insta-profile-reels", "1");
        }
        if (nodes[j].getAttribute("aria-disabled") !== "true") nodes[j].setAttribute("aria-disabled", "true");
        if (nodes[j].getAttribute("tabindex") !== "-1") nodes[j].setAttribute("tabindex", "-1");
      }
    }
  }

  /*
   * Explore nav: only elements whose accessible name contains "explore"
   * and does not contain "search". Default selector a[aria-label='Explore'].
   * Must not match Search. On mobile, Search often uses href /explore/.
   * Failure: if Search is labeled Explore, clear explore.navSelectors.
   * Grid: main article on the explore route (assumption). Skipped when the
   * element contains the search field. Failure: the grid is not articles;
   * add the real selector to explore.gridSelectors.
   */
  function applyExplore() {
    hideExploreNav();
    if (!isExploreKeepPage()) return;
    var grids = safeSelectors(config.explore && config.explore.gridSelectors);
    var i;
    for (i = 0; i < grids.length; i++) {
      var nodes;
      try {
        nodes = document.querySelectorAll(grids[i]);
      } catch (e) {
        continue;
      }
      var j;
      for (j = 0; j < nodes.length; j++) {
        var el = nodes[j];
        if (el.closest && el.closest("nav, header")) continue;
        if (containsSearchUI(el)) continue;
        if (el.getAttribute("data-insta-explore-hide") !== "1") el.setAttribute("data-insta-explore-hide", "1");
      }
    }
  }

  function hideExploreNav() {
    var selectors = safeSelectors(config.explore && config.explore.navSelectors);
    var i;
    for (i = 0; i < selectors.length; i++) {
      var nodes;
      try {
        nodes = document.querySelectorAll(selectors[i]);
      } catch (e) {
        continue;
      }
      var j;
      for (j = 0; j < nodes.length; j++) {
        var el = nodes[j];
        var label = ((el.getAttribute && el.getAttribute("aria-label")) || "").toLowerCase();
        var text = (el.innerText || "").toLowerCase().trim();
        if (label.indexOf("search") !== -1 || text === "search") continue;
        if (label.indexOf("explore") === -1 && text.indexOf("explore") === -1) continue;
        if (el.getAttribute("data-insta-explore-nav") !== "1") el.setAttribute("data-insta-explore-nav", "1");
      }
    }
  }

  function containsSearchUI(el) {
    var keeps = safeSelectors(config.explore && config.explore.searchKeepSelectors);
    var i;
    for (i = 0; i < keeps.length; i++) {
      try {
        if (el.matches(keeps[i]) || el.querySelector(keeps[i])) return true;
      } catch (e) {}
    }
    return false;
  }

  function reelIdFromPath(pathname) {
    var path = normalizePath(pathname);
    var match = path.match(/^\/reel\/([^/]+)$/);
    if (match) return match[1];
    match = path.match(/^\/[^/]+\/reel\/([^/]+)$/);
    if (match) return match[1];
    if (!config.reels || config.reels.allowIdPaths !== false) {
      match = path.match(/^\/reels\/([^/]+)$/);
      if (match) return match[1];
    }
    match = path.match(/^\/p\/([^/]+)$/);
    if (match) return "p:" + match[1];
    return null;
  }

  function isDirectReelPath(pathname) {
    var path = normalizePath(pathname);
    if (/^\/reel\/[^/]+$/.test(path)) return true;
    if (/^\/[^/]+\/reel\/[^/]+$/.test(path)) return true;
    if ((!config.reels || config.reels.allowIdPaths !== false) && /^\/reels\/[^/]+$/.test(path)) return true;
    return false;
  }

  function syncReelLock() {
    var lockConfig = config.reelLock || {};
    if (!enabled || lockConfig.enabled === false || !isInstagramPage()) {
      releaseLock(true);
      return;
    }
    var path = normalizePath(location.pathname);
    if (isReelsFeedPath(path)) {
      releaseLock(false);
      return;
    }
    if (path.indexOf("/stories") === 0) {
      releaseLock(true);
      return;
    }
    var pathId = reelIdFromPath(path);
    if (lock.active && pathId && lock.reelId && pathId !== lock.reelId) {
      restoreLockedURL();
      return;
    }
    if (pathId && isDirectReelPath(path)) {
      if (!lock.active) engageLock(pathId, location.href);
      else refreshLockUI();
      return;
    }
    if (pathId && pathId.indexOf("p:") === 0 && findViewerRoot()) {
      if (!lock.active) engageLock(pathId, location.href);
      else refreshLockUI();
      return;
    }
    var modal = detectModalReel();
    if (modal) {
      if (!lock.active) engageLock(modal.id, modal.url);
      else refreshLockUI();
      return;
    }
    if (lock.active) releaseLock(true);
  }

  function detectModalReel() {
    if (normalizePath(location.pathname).indexOf("/stories") === 0) return null;
    var dialogs;
    try {
      dialogs = document.querySelectorAll("[role='dialog']");
    } catch (e) {
      return null;
    }
    var i;
    for (i = 0; i < dialogs.length; i++) {
      var dialog = dialogs[i];
      if (isStoryDialog(dialog)) continue;
      var link = dialog.querySelector("a[href*='/reel/'], a[href*='/reels/']");
      if (!link) continue;
      var path = pathFromHref(link.getAttribute("href"));
      var id = path ? reelIdFromPath(path) : null;
      if (!id || id.indexOf("p:") === 0) continue;
      if (!dialog.querySelector("video")) continue;
      var absolute = location.href;
      try {
        absolute = new URL(link.getAttribute("href"), location.origin).href;
      } catch (e) {}
      return { id: id, url: absolute };
    }
    return null;
  }

  function isStoryDialog(dialog) {
    if (!dialog) return false;
    var label = ((dialog.getAttribute && dialog.getAttribute("aria-label")) || "").toLowerCase();
    if (label.indexOf("story") !== -1) return true;
    try {
      if (dialog.querySelector("a[href*='/stories/']")) return true;
      if (dialog.querySelector("[aria-label*='Story'], [aria-label*='story']")) return true;
    } catch (e) {}
    return false;
  }

  function engageLock(id, url) {
    if (!lock.active) {
      lock.active = true;
      lock.reelId = id;
      lock.url = url || location.href;
    }
    refreshLockUI();
  }

  function refreshLockUI() {
    var root = findViewerRoot();
    if (!root) return;
    applyLockStyles(root);
    if (!config.reelLock || config.reelLock.hideNextPrev !== false) markNextPrev(root);
    ensureListeners(root);
  }

  /*
   * Viewer root is the dialog or a configured scroll container that holds
   * the visible video. Stories are refused. Must not be body/html.
   * Failure: the reel player is not a video element yet, so the lock waits
   * for a later DOM pass. Gesture lock then attaches to that root only.
   */
  function findViewerRoot() {
    var selectors = safeSelectors(config.reelLock && config.reelLock.videoSelectors);
    if (selectors.length === 0) selectors = ["video"];
    var videos;
    try {
      videos = document.querySelectorAll(selectors.join(","));
    } catch (e) {
      return null;
    }
    var video = null;
    var i;
    for (i = 0; i < videos.length; i++) {
      if (isVisible(videos[i])) video = videos[i];
    }
    if (!video) return null;
    if (video.closest && video.closest("[aria-label*='Story'], [aria-label*='story']")) return null;
    var dialog = video.closest ? video.closest("[role='dialog']") : null;
    if (dialog && isStoryDialog(dialog)) return null;
    var containers = safeSelectors(config.reelLock && config.reelLock.scrollContainerSelectors);
    var scope = dialog || document;
    var c;
    for (c = 0; c < containers.length; c++) {
      var nodes;
      try {
        nodes = scope.querySelectorAll(containers[c]);
      } catch (e) {
        continue;
      }
      var n;
      for (n = 0; n < nodes.length; n++) {
        if (nodes[n] === document.body || nodes[n] === document.documentElement) continue;
        if (nodes[n] === video || (nodes[n].contains && nodes[n].contains(video))) {
          if (nodes[n].tagName === "MAIN" && !dialog) continue;
          return nodes[n];
        }
      }
    }
    if (dialog) return dialog;
    var parent = video.parentElement;
    if (!parent || parent === document.body || parent === document.documentElement) return null;
    return parent;
  }

  function isVisible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    var rect = el.getBoundingClientRect();
    return rect.width > 20 && rect.height > 20;
  }

  function applyLockStyles(root) {
    if (lock.styledRoot === root) {
      if (root.getAttribute("data-insta-locked") !== "1") root.setAttribute("data-insta-locked", "1");
      return;
    }
    restoreStyles();
    lock.styledRoot = root;
    lock.prevOverflow = root.style.overflow || "";
    lock.prevOverscroll = root.style.overscrollBehavior || "";
    lock.prevTouchAction = root.style.touchAction || "";
    root.style.overflow = "hidden";
    root.style.overscrollBehavior = "none";
    root.style.touchAction = "none";
    root.setAttribute("data-insta-locked", "1");
  }

  function restoreStyles() {
    var root = lock.styledRoot;
    if (!root) return;
    var restore = !config.reelLock || config.reelLock.restoreScrollOnClose !== false;
    if (restore) {
      root.style.overflow = lock.prevOverflow || "";
      root.style.overscrollBehavior = lock.prevOverscroll || "";
      root.style.touchAction = lock.prevTouchAction || "";
    } else {
      root.style.overflow = "";
      root.style.overscrollBehavior = "";
      root.style.touchAction = "";
    }
    if (root.removeAttribute) root.removeAttribute("data-insta-locked");
    lock.styledRoot = null;
  }

  function markNextPrev(root) {
    var selectors = safeSelectors(config.reelLock && config.reelLock.nextPrevSelectors);
    var i;
    for (i = 0; i < selectors.length; i++) {
      var nodes;
      try {
        nodes = root.querySelectorAll(selectors[i]);
      } catch (e) {
        continue;
      }
      var j;
      for (j = 0; j < nodes.length; j++) {
        if (nodes[j].getAttribute("data-insta-reel-next") !== "1") nodes[j].setAttribute("data-insta-reel-next", "1");
        if (nodes[j].getAttribute("aria-disabled") !== "true") {
          nodes[j].setAttribute("aria-disabled", "true");
          nodes[j].setAttribute("data-insta-set-aria", "1");
        }
        if (nodes[j].getAttribute("tabindex") !== "-1") {
          nodes[j].setAttribute("tabindex", "-1");
          nodes[j].setAttribute("data-insta-set-tab", "1");
        }
      }
    }
  }

  function ensureListeners(root) {
    if (lock.root === root && lock.listeners.length > 0) return;
    removeListeners();
    lock.root = root;
    var options = { capture: true, passive: false };
    addListener(root, "touchstart", onTouchStart, options);
    addListener(root, "touchmove", onTouchMove, options);
    if (!config.reelLock || config.reelLock.lockWheel !== false) {
      addListener(root, "wheel", onWheel, options);
    }
    addListener(root, "click", onLockedClick, options);
    addListener(document, "keydown", onKeyDown, options);
  }

  function addListener(el, type, fn, options) {
    el.addEventListener(type, fn, options);
    lock.listeners.push({ el: el, type: type, fn: fn, options: options });
  }

  function removeListeners() {
    var i;
    for (i = 0; i < lock.listeners.length; i++) {
      var item = lock.listeners[i];
      try {
        item.el.removeEventListener(item.type, item.fn, item.options);
      } catch (e) {}
    }
    lock.listeners = [];
    lock.root = null;
    lock.tracking = false;
  }

  function shouldAllowGesture(target) {
    if (!target || !target.closest) return false;
    if (target.closest("[data-insta-reel-next='1']")) return false;
    var selectors = safeSelectors(config.reelLock && config.reelLock.allowScrollSelectors);
    var i;
    for (i = 0; i < selectors.length; i++) {
      try {
        if (target.closest(selectors[i])) return true;
      } catch (e) {}
    }
    return false;
  }

  function onTouchStart(event) {
    if (!lock.active) return;
    if (!event.touches || event.touches.length !== 1) {
      lock.tracking = false;
      return;
    }
    if (shouldAllowGesture(event.target)) {
      lock.tracking = false;
      return;
    }
    lock.sx = event.touches[0].clientX;
    lock.sy = event.touches[0].clientY;
    lock.tracking = true;
  }

  function onTouchMove(event) {
    if (!lock.active || !lock.tracking) return;
    if (!event.touches || event.touches.length !== 1) return;
    if (shouldAllowGesture(event.target)) return;
    var touch = event.touches[0];
    var dx = Math.abs(touch.clientX - lock.sx);
    var dy = Math.abs(touch.clientY - lock.sy);
    var threshold = Number(config.reelLock && config.reelLock.swipeThresholdPx);
    if (!isFinite(threshold) || threshold < 0) threshold = 10;
    if (dy > threshold && dy > dx) {
      if (event.cancelable) event.preventDefault();
      event.stopImmediatePropagation();
    }
  }

  function onWheel(event) {
    if (!lock.active) return;
    if (config.reelLock && config.reelLock.lockWheel === false) return;
    if (shouldAllowGesture(event.target)) return;
    if (event.deltaY === 0) return;
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
  }

  function onLockedClick(event) {
    if (!lock.active) return;
    var target = event.target;
    if (!target || !target.closest) return;
    if (target.closest("[data-insta-reel-next='1']")) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }

  function onKeyDown(event) {
    if (!lock.active) return;
    if (shouldAllowGesture(event.target)) return;
    var key = event.key;
    if (key === "ArrowUp" || key === "ArrowDown" || key === "PageUp" || key === "PageDown") {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }

  function restoreLockedURL() {
    if (!lock.url) return;
    if (config.reelLock && config.reelLock.forceReelIdBack === false) return;
    if (restoring) return;
    if (location.href === lock.url) return;
    restoring = true;
    try {
      history.replaceState(history.state, "", lock.url);
    } catch (e) {}
    restoring = false;
  }

  function releaseLock(restoreScroll) {
    removeListeners();
    if (restoreScroll) restoreStyles();
    else if (lock.styledRoot) restoreStyles();
    var marked;
    try {
      marked = document.querySelectorAll("[data-insta-reel-next='1']");
    } catch (e) {
      marked = [];
    }
    var i;
    for (i = 0; i < marked.length; i++) {
      marked[i].removeAttribute("data-insta-reel-next");
      if (marked[i].getAttribute("data-insta-set-aria") === "1") {
        marked[i].removeAttribute("aria-disabled");
        marked[i].removeAttribute("data-insta-set-aria");
      }
      if (marked[i].getAttribute("data-insta-set-tab") === "1") {
        marked[i].removeAttribute("tabindex");
        marked[i].removeAttribute("data-insta-set-tab");
      }
    }
    lock.active = false;
    lock.reelId = null;
    lock.url = null;
  }

  function clearMarks() {
    var root = document.documentElement;
    if (root) {
      root.classList.remove("insta-home");
      root.classList.remove("insta-explore");
      root.classList.remove("insta-reels-hidden");
    }
    var selector = "[data-insta-hide],[data-insta-reels-nav],[data-insta-explore-hide],[data-insta-explore-nav],[data-insta-profile-reels],[data-insta-reel-next],[data-insta-locked]";
    var nodes;
    try {
      nodes = document.querySelectorAll(selector);
    } catch (e) {
      nodes = [];
    }
    var i;
    for (i = 0; i < nodes.length; i++) {
      nodes[i].removeAttribute("data-insta-hide");
      nodes[i].removeAttribute("data-insta-reels-nav");
      nodes[i].removeAttribute("data-insta-explore-hide");
      nodes[i].removeAttribute("data-insta-explore-nav");
      nodes[i].removeAttribute("data-insta-profile-reels");
      nodes[i].removeAttribute("data-insta-reel-next");
      nodes[i].removeAttribute("data-insta-locked");
      if (nodes[i].getAttribute("data-insta-set-aria") === "1") {
        nodes[i].removeAttribute("aria-disabled");
        nodes[i].removeAttribute("data-insta-set-aria");
      }
      if (nodes[i].getAttribute("data-insta-set-tab") === "1") {
        nodes[i].removeAttribute("tabindex");
        nodes[i].removeAttribute("data-insta-set-tab");
      }
    }
    var keeps;
    try {
      keeps = document.querySelectorAll(".insta-stories-keep");
    } catch (e) {
      keeps = [];
    }
    for (i = 0; i < keeps.length; i++) keeps[i].classList.remove("insta-stories-keep");
  }

  function postLog(message) {
    try {
      var text = String(message).replace(/[\r\n]/g, " ").slice(0, 180);
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.instaBridge;
      if (!bridge) return;
      bridge.postMessage({ kind: "log", message: text });
    } catch (e) {}
  }
})();
