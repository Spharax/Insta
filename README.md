# Insta

A personal iOS shell around Instagram's mobile website. It is not affiliated with Instagram or Meta, it does not use private APIs, and it is not an App Store app. The home feed is hidden, the Reels tab stays visible but does not navigate, the Reels feed is sent back to home, and a single opened reel cannot be swiped to the next one.

This repository has no `.xcodeproj`. GitHub Actions generates it with XcodeGen and uploads an unsigned `.ipa`.

**Nothing here was run against Instagram's live site or on a device.** Selectors are assumptions. When Instagram changes its HTML, edit the remote JSON. You do not need a new build for selector changes after the remote URL below is set.

## Assumptions and defaults

- **ID search** means Instagram's Search box: type a username or numeric ID, open that account's profile. It does not mean a separate native ID lookup. If you meant something else, change `allowedPaths` and the Explore settings.
- **Profile Reels tab** (`/<username>/reels/`) is treated as a Reels listing. `profile.hideReelsTab` defaults to `true`, so that tab is hidden and that path redirects home. Profile posts and `/<username>/reel/<id>/` stay available.
- **`/reels/<id>/`** (an ID on the plural path) is an individual reel, not the feed. `reels.allowIdPaths` defaults to `true` because some DM links use this shape. The single-reel lock applies. Set `allowIdPaths` to `false` to redirect those URLs home.
- **`/p/<id>/`** is a single post. It is allowed. The reel lock turns on only when that page is showing a visible `<video>`.
- **`explore.mode`** defaults to `hideGridKeepSearch`. `/explore/` and `/explore/search/` are not redirected, because mobile Search often lives there. Hashtag and location pages are redirected.
- **Reels nav** defaults to `disabled-visible` at opacity `0.4`. It is not removed and `pointer-events` is not set to `none`.
- **Home** is `pathname === "/"` after removing a trailing slash. `/?variant=following` and `/?variant=favorites` are still home. The feed is hidden with CSS. The page is not redirected.
- **Safety allows cannot be removed by remote config:** `/accounts`, `/challenge`, `/consent`, `/direct`, `/stories`, legal/privacy/about/oauth, `/reel/<id>`, `/<username>/reel/<id>`, and `/p/<id>`. This is so a bad regex cannot lock you out of login. The exact Reels feed is blocked *before* allow regexes, so a broad pattern cannot turn the feed back on.
- The redirect target is never itself blocked. The default target is `/`.
- The app icon is a generic gradient camera, not Meta's Instagram logo.

## Fragility

Instagram's web UI is a moving target. Class names, `aria-label`s, and route shapes change without notice. When something breaks, use desktop DevTools with a phone-sized window and the user agent in `Insta/App/AppConstants.swift`. A Debug build also sets `isInspectable = true` (iOS 16.4+) so Safari's Develop menu can attach. The GitHub Actions archive is Release, so the IPA you sideload is not inspectable. Then edit the JSON. Do not delete React-managed nodes; this app only hides them.

## What you get

| Item | Value |
| --- | --- |
| Display name | Insta |
| Bundle ID | `com.personal.insta` |
| Scheme | `Insta` |
| Deployment | iOS 17.0, iPhone |
| Swift language mode | Swift 5 (`SWIFT_VERSION` `5.0` in `project.yml`). Do not set `5.9`; that is not a valid `SWIFT_VERSION`. The compiler may still be Swift 6. |
| IPA | `Insta.ipa` |
| Artifact | `instagram-stories-only-unsigned-ipa` |
| Cookies | `WKWebsiteDataStore.default()` |
| User agent | `AppConstants.defaultUserAgent` |

Current user agent (change it in `Insta/App/AppConstants.swift` when mobile Safari's string changes):

```text
Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1
```

## Push the repo and build the IPA

1. Create an empty GitHub repository. Do not add a README there if you are about to push this one.
2. Copy this folder (the directory that contains `project.yml`) into that repo. Do not commit an `.xcodeproj`.
3. `Insta/App/AppConstants.swift` already points `remoteConfigURLString` at this repo: `https://raw.githubusercontent.com/Spharax/Insta/main/Config/remote-config.example.json`. The repo must stay public or that fetch 404s. If you fork it, change the URL and rebuild once. Until the URL contains a real host, the app uses the bundled config and skips the network fetch.
4. Commit and push to `main`.

```bash
git init
git add .
git commit -m "Add Insta"
git branch -M main
git remote add origin https://github.com/Spharax/Insta.git
git push -u origin main
```

5. On GitHub, open **Actions**. If this is the repo's first workflow, click the prompt to enable Actions.
6. Pushing to `main` starts **Build unsigned IPA**. You can also open that workflow and click **Run workflow**.
7. When the job is green, open the run, scroll to **Artifacts**, and download `instagram-stories-only-unsigned-ipa`. Inside the zip from GitHub is `Insta.ipa`.

You do not run Xcode or any local command. The workflow installs XcodeGen, runs `xcodegen generate`, archives with `CODE_SIGNING_ALLOWED=NO`, and zips `Payload/Insta.app` itself. It does **not** call `xcodebuild -exportArchive`.

## Sideload

Use AltStore, SideStore, Sideloadly, or TrollStore (if you already use it). This project does not include a sideloading tool.

Typical AltStore / SideStore flow:

1. Install AltServer (AltStore) or SideStore's pairing flow on a computer, and the store app on the phone.
2. In the store, use the plus button or "Sideload IPA" and pick `Insta.ipa`.
3. Sign in with your Apple ID when asked. The app's bundle ID is `com.personal.insta`.

**Free Apple ID:** the provisioning profile lasts about **7 days**. After that the app will not launch until you refresh it from AltStore/SideStore on the same Wi-Fi as the computer (or your SideStore refresh setup). You can only have a few sideloaded app IDs at once.

**Paid Apple Developer Program:** profiles last about **1 year**, and you can refresh less often. This IPA is still unsigned when you download it; the sideloading tool signs it with your team. There is no App Store submission in this repo.

The first launch is a blank launch screen, then Instagram's site. Log in, including 2FA, in the web view. The session is the system web view cookie store. This app never reads or stores your password. Log out from Instagram's own settings.

DM attachment upload works only if Instagram's website offers it. There is no separate native uploader. Camera, microphone, and photo-library usage strings are in the Info.plist so the website's file picker can ask for permission.

## Remote config

Load order:

1. Cached config from a previous successful fetch, if it still validates.
2. Otherwise `Insta/Resources/fallback-config.json` inside the app.
3. If that file is missing or invalid, a hardcoded copy in `AppConfig.fallback`.
4. Then a background refresh from `AppConstants.remoteConfigURLString`.

A bad download (offline, HTTP error, broken JSON, unknown `schemaVersion`, invalid regex, unsafe selector, redirect target equal to the Reels feed) is discarded. The previous good config stays. The app does not eval JavaScript from the JSON. Only selectors, regexes, numbers, booleans, and the enums below are read.

The fetch uses an ephemeral `URLSession` with `reloadIgnoringLocalCacheData`, and the request uses `reloadIgnoringLocalAndRemoteCacheData`, with a 15 second timeout.

### Hosting

The intended file is `Config/remote-config.example.json` (same contents as the bundled file). After the first push:

`https://raw.githubusercontent.com/Spharax/Insta/main/Config/remote-config.example.json`

Set that URL in `AppConstants.remoteConfigURLString` **before** the build that should start fetching. Changing the URL requires a rebuild. Changing the JSON after that does not. In the app, the slider button opens **Reload rules**, which fetches again. You can also kill and reopen the app; it refreshes on launch.

`schemaVersion` must be `1`.

### Explore and Search

Mobile Instagram often opens Search at `/explore/` or `/explore/search/`. Redirecting those paths breaks Search.

- `hideGridKeepSearch` (default): do not redirect `/explore/` or `/explore/search/`. Hide elements matching `explore.gridSelectors` (default `main article`) unless they contain the search field. Hide a nav control only when its label contains "explore" and not "search". The generic `a[href='/explore/']` selector is intentionally **not** the default, because that is often the Search button.
- `blockAll`: also redirect `/explore/` and `/explore/search/` home. Use this only after you confirm Search does not need those paths.

Hashtag and location browsing (`/explore/tags/...`, `/explore/locations/...`) redirects home in both modes unless you clear `blockBrowsePathPatterns`.

If Search disappears, set `explore.navSelectors` to `[]` and push the JSON.

## Path rules

Paths are normalized by removing the query and the fragment, collapsing repeated slashes (`//reels` becomes `/reels`), lowercasing, and removing a trailing slash (`/` stays `/`). Allow rules beat later block rules. Hardcoded safety paths (login, DMs, Stories, an individual reel or post) are allowed before any configurable feed or id pattern, so `feedPathPattern` cannot be pointed at `/direct`. The literal path `/reels` is still blocked when `blockFeed` is on, before the configurable allow list.

Order in `PathPolicy.swift` and `bridge.js`:

1. If the path is the redirect target, allow (loop protection).
2. If the path matches the hardcoded safety list, allow.
3. If `reels.blockFeed` and the path is `/reels` or matches `feedPathPattern`, block.
4. If the path is a Reels listing rather than one id (`/reels/audio`, `/reels/audio/<id>`, `/reels/<id>/<extra>`), block.
5. If `allowIdPaths` is false and the path matches `idPathPattern` (`^/reels/[^/]+$`), block.
6. If the path matches a safety allow, `allowedPaths`, `allowReelPathPattern`, `allowUserReelPathPattern`, `postPathPattern`, the id pattern when `allowIdPaths` is true, or Explore's always-allow patterns when mode is not `blockAll`, allow.
7. If `profile.hideReelsTab` and the path matches `^/[^/]+/reels$`, block.
8. If the path matches an Explore browse pattern, block.
9. If mode is `blockAll` and the path matches an Explore always-allow pattern, block.
10. If the path is any other `/explore` URL, block.
11. If the path matches `blockedPaths`, block.
12. Otherwise allow (profiles and unknown account pages).

`^/reels$` does not match `/reel/<id>` or `/reels/<id>`. `^/reel/[^/]+$` does not match `/reels`. `/Reels` is the same as `/reels` after lowercasing.

| URL | Result |
| --- | --- |
| `/` | Allow. Hide the feed. Stories and nav stay. |
| `/?variant=following` | Allow. Path is still `/`. Feed stays hidden. |
| `/reels/` | Block. Redirect home. |
| `/Reels` and `//reels` | Block. Same path as `/reels` after normalization. |
| `/reels/<id>/` | Allow and lock (`allowIdPaths` default true). |
| `/reels/audio/` and `/reels/audio/<id>/` | Block. This is a scrollable audio listing, not one reel. |
| `/reel/<id>/` | Allow and lock. |
| `/<username>/reel/<id>/` | Allow and lock. |
| `/<username>/` | Allow. Profile header, bio, and posts grid. |
| `/<username>/reels/` | Block. Redirect home (`hideReelsTab` default true). |
| `/explore/` | Allow, hide the grid (`hideGridKeepSearch`). |
| `/explore/search/` | Allow. Search stays usable. |
| `/explore/<anything else>/` | Block, including tags and locations. |
| `/stories/<user>/<id>/` | Allow. Not a reel lock. |
| `/direct/inbox/` | Allow. |
| `/direct/t/<id>/` | Allow. |
| `/accounts/login/` | Allow. |
| `/accounts/edit/` | Allow. |

`scripts/check_path_rules.py` checks this table against the JSON and checks that the Swift and JavaScript safety lists match. It does not launch the app. Run it with `python3 scripts/check_path_rules.py` if you change regexes.

Scripts are injected at **document start**, **main frame only**. Iframes (captcha, some login widgets) are left alone so sign-in is not redirected. Instagram's UI is the top document. SPA navigations are covered by wrapping `history.pushState` and `history.replaceState` (replaceState does not emit `popstate` by itself), plus `popstate`, `hashchange`, a throttled `MutationObserver` (250 ms, `childList` only), and a 1.5 s interval. Redirects use `location.replace` so the blocked URL is not left in history. After 6 redirects inside 10 seconds the script stops and shows a "Go home" banner.

The native `WKNavigationDelegate` cancels main-frame loads of blocked Instagram paths and loads `https://www.instagram.com/` instead. That check is skipped while Restrictions is off, which is the same switch the page script uses. `decisionHandler` is called once. Subframes are allowed. Non-allowlisted http(s) URLs open in Safari. `instagram://` and other custom schemes are cancelled so they do not open the App Store app. `mailto`, `tel`, and `sms` still open outside. `target="_blank"` is handled in `WKUIDelegate.createWebViewWith` so the link is not dropped. If the web content process dies and `webView.url` is nil, the app loads the home URL instead of calling `reload()`.

### In-app allowlist

These hosts stay in the web view (exact host or a subdomain):

`instagram.com`, `cdninstagram.com`, `facebook.com`, `fbcdn.net`, `facebook.net`, `fb.com`, `fbsbx.com`, `meta.com`, `messenger.com`, `threads.net`, plus sign-in hosts `google.com`, `googleapis.com`, `gstatic.com`, `googleusercontent.com`, `apple.com`, and `icloud.com` (so Google and Apple login can return to this web view).

Path rules apply only on `instagram.com` and its subdomains. CDN, Facebook, Google, and Apple hosts are not run through the Reels matcher. Any other http(s) host opens in Safari. A redirect target of `//evil.com` is rejected; `location.replace` only receives a same-origin path. `feedPathPattern` and `idPathPattern` are also rejected when they full-match a login, DM, Story, or post path. Selectors may use `>` (a child combinator). `{`, `}`, `<`, and `/*` are rejected in both Swift and the page script. A comma-separated selector is prefixed on every part, so `a, b` does not leak out of `html.insta-home`.

## Selectors

All of these are assumptions. Comments in `Insta/Resources/bridge.js` repeat the failure mode.

| Config key | Default | Targets | Must not match | If it breaks |
| --- | --- | --- | --- | --- |
| `feed.hideSelectors` | `article` | Home-feed posts. CSS is prefixed with `html.insta-home`, so other routes are not affected. | Stories tray, nav, DM threads, profile grids. | If posts are not `article`, add the real selector. If the tray is an `article`, it is marked `.insta-stories-keep` when it contains story links and no `<time>`. |
| `feed.storiesSelectors` | `a[href^='/stories/']` and `a[href*='/stories/']` | Story rings. | Reel links. | If story URLs change, the tray can be hidden with the feed. Fix the selector. |
| `feed.storiesTrayAncestorDepth` | `4` | How far to walk up from a story link to mark the tray. Stops before `main` / `nav`, and stops if the node also contains a non-story `article`. | The feed column. | Lower the depth if the whole feed becomes visible. Raise it if only single rings show. |
| `feed.hideTextSnippets` | Suggested for you, You're all caught up, Suggested accounts | Headings that are not posts. The nearest `article` or `section` is hidden, not `body`. | Nav, header, stories tray. | Update the phrases when Instagram changes the copy. |
| `feed.keepSelectors` | `nav`, `header`, `[role='tablist']` | Chrome that must not receive `data-insta-hide`. | Feed posts. | Don't add `main` here. |
| `reelsNav.selectors` | `a[href='/reels/']`, `a[href='/reels']` | The bottom Reels entry, and only after the path is normalized to exactly `/reels`. | `/reel/<id>`, `/reels/<id>`, `/<user>/reels`, Home, Search, Create, Profile. | If the control is a `<div>` with a new label, set `labelMatchers`. |
| `reelsNav.labelMatchers` | `Reels` | `aria-label` equal to this string, inside `nav` / `tablist` / `navigation`. | A profile tab whose `href` is `/<user>/reels` (that path is excluded). | Match the new accessible name exactly. |
| `reelsNav.navRootSelectors` | `nav`, `[role='tablist']`, `[role='navigation']` | Where the Reels control is searched. | The whole document. | Narrow this if a non-nav "Reels" label gets dimmed. |
| `explore.navSelectors` | `a[aria-label='Explore']`, `[aria-label='Explore']` | A control whose label contains "explore" and not "search". | The Search button, even if its `href` is `/explore/`. | Set this to `[]` if Search vanishes. |
| `explore.gridSelectors` | `main article` | Discovery tiles on `/explore/` and `/explore/search/`. | The search field. Any match that contains a `searchKeepSelectors` node is skipped. | If the grid is not `article`, inspect and replace this. If account results are articles and disappear, clear this list. |
| `explore.searchKeepSelectors` | search inputs and `[role='search']` | The search box that must remain. | Grid tiles. | Update placeholders if the input is no longer named Search. |
| `profile.reelsTabSelectors` | `a[href$='/reels/']`, `a[href$='/reels']` | Candidates only. A node is hidden only when its path matches `^/[^/]+/reels$`. | The bottom link to `/reels`. | If the tab has no `href`, the redirect still catches the route once it changes. |
| `reelLock.viewerSelectors` | `[role='dialog']` | Documented viewer root. | Story dialogs (`aria-label` or links containing Story / `/stories/`). | Adjust if the player is not a dialog. |
| `reelLock.scrollContainerSelectors` | `[role='dialog']`, `[role='presentation']` | The element that receives the gesture lock. `main` is not the default. `body` is never locked. | Comment fields (those use `allowScrollSelectors`). | If swipes still advance, set this to the element that actually scrolls. |
| `reelLock.videoSelectors` | `video` | Visible video used to find the viewer. | Story videos, which are rejected via the story checks. | Change if Instagram stops using `<video>`. |
| `reelLock.nextPrevSelectors` | `aria-label` Next / Previous / Up Next / Next video, queried **inside the viewer only** | Reel next and previous controls. | Story next buttons outside the viewer. | Add the real `aria-label`. Swipes are still blocked when the label is wrong. |
| `reelLock.allowScrollSelectors` | `textarea`, `input`, `form`, comment labels | Comment and share fields, so their vertical scroll still works. | The reel viewport itself. | Add the comment sheet's real selector if comments cannot scroll. |

`feed.keepSelectors` is not a CSS hide list. Home hiding is `html.insta-home article` plus `[data-insta-hide='1']`. Nodes are never removed.

## Reels button

Default `reelsNav.mode` is `disabled-visible`.

- CSS sets opacity from `dimOpacity` (default 0.4) and `-webkit-touch-callout: none` on `[data-insta-reels-nav='1']` only.
- JS sets `aria-disabled="true"` and `tabindex="-1"`.
- A document capture listener on `click`, `pointerdown`, `pointerup`, `touchstart`, `touchend`, and `auxclick` calls `preventDefault()` and `stopImmediatePropagation()` when `event.composedPath()` or `closest()` hits that element. Touch listeners are `{ passive: false, capture: true }` so `preventDefault` works on iOS.
- `pointer-events` is not `none`, so the tap does not fall through to whatever is behind the button.
- `mode: "hidden"` adds `html.insta-reels-hidden`, which uses `visibility: hidden` (the slot stays in the bar). The interceptor still runs.
- The observer re-applies the attribute when Instagram redraws the bar. The attribute is written only when it is not already set.

Neighboring items are not given the attribute unless their own href normalizes to exactly `/reels` or their aria-label is exactly `Reels`.

## Single-reel lock

The lock turns on for `/reel/<id>/`, `/<username>/reel/<id>/`, `/reels/<id>/` when allowed, a `/p/<id>/` page with a visible video, or a `role="dialog"` that contains a video and a reel link and does not look like Stories. Stories never lock.

While active:

- The viewer root gets `overflow: hidden`, `overscroll-behavior: none`, and `touch-action: none` (CSS plus inline). Taps still produce clicks. `touch-action: none` blocks the browser pan, not the like button.
- `touchmove` calls `preventDefault` only when one finger has moved more than `swipeThresholdPx` (default 10) and the movement is more vertical than horizontal, and the target is not an allow-scroll control.
- `wheel` is cancelled when `lockWheel` is true (default), except on those same controls.
- Arrow Up/Down and Page Up/Down are cancelled. Space is not, so a focused control can still activate and video pause is left alone.
- Next/previous controls inside the viewer are `visibility: hidden` and their clicks are cancelled. `pointer-events` is not set to `none`.
- If the URL's reel id changes, `history.replaceState` puts back the original URL. The wrapper ignores that call (`restoring`) so it does not loop. `replaceState` itself does not fire `popstate`.
- If the URL becomes the Reels feed, the lock releases and the feed redirect sends you home.
- On close, listeners are removed with the same capture options, the attribute and inline lock styles are cleared (`restoreScrollOnClose`, default true), and scrolling outside the viewer was never locked.

Like, comment, share, save, mute, and close are taps. Comment fields match `allowScrollSelectors` so their own scrolling is not cancelled.

## Example config (annotated)

This block is documentation. It is not the file the app parses. The real files are `Insta/Resources/fallback-config.json` and `Config/remote-config.example.json`.

```jsonc
{
  "schemaVersion": 1,
  "configVersion": "1.0.0",
  "feed": {
    "homePath": "/",
    "hideSelectors": ["article"],
    "storiesSelectors": ["a[href^='/stories/']", "a[href*='/stories/']"],
    "storiesTrayAncestorDepth": 4,
    "hideTextSnippets": ["Suggested for you", "You're all caught up", "Suggested accounts"],
    "keepSelectors": ["nav", "header", "[role='tablist']"]
  },
  "reelsNav": {
    "mode": "disabled-visible",
    "navRootSelectors": ["nav", "[role='tablist']", "[role='navigation']"],
    "selectors": ["a[href='/reels/']", "a[href='/reels']"],
    "labelMatchers": ["Reels"],
    "dimOpacity": 0.4,
    "interceptEvents": ["click", "pointerdown", "pointerup", "touchstart", "touchend", "auxclick"]
  },
  "explore": {
    "mode": "hideGridKeepSearch",
    "navSelectors": ["a[aria-label='Explore']", "[aria-label='Explore']"],
    "gridSelectors": ["main article"],
    "searchKeepSelectors": ["input[type='search']", "input[aria-label='Search']", "[role='search']"],
    "alwaysAllowPathPatterns": ["^/explore$", "^/explore/search(?:/.*)?$"],
    "blockBrowsePathPatterns": ["^/explore/tags(?:/.*)?$", "^/explore/locations(?:/.*)?$"]
  },
  "profile": {
    "hideReelsTab": true,
    "reelsTabSelectors": ["a[href$='/reels/']", "a[href$='/reels']"],
    "reelsTabPathPattern": "^/[^/]+/reels$"
  },
  "redirect": { "targetPath": "/", "method": "replace", "maxRedirects": 6, "windowMs": 10000 },
  "blockedPaths": ["^/reels$"],
  "allowedPaths": ["^/$", "^/accounts(?:/.*)?$", "^/direct(?:/.*)?$", "^/stories(?:/.*)?$", "^/reel/[^/]+$", "^/reels/[^/]+$"],
  "reels": {
    "blockFeed": true,
    "feedPathPattern": "^/reels$",
    "allowReelPathPattern": "^/reel/[^/]+$",
    "allowUserReelPathPattern": "^/[^/]+/reel/[^/]+$",
    "allowIdPaths": true,
    "idPathPattern": "^/reels/[^/]+$",
    "postPathPattern": "^/p/[^/]+$"
  },
  "reelLock": {
    "enabled": true,
    "viewerSelectors": ["[role='dialog']"],
    "scrollContainerSelectors": ["[role='dialog']", "[role='presentation']"],
    "swipeThresholdPx": 10,
    "lockWheel": true,
    "hideNextPrev": true,
    "nextPrevSelectors": ["[aria-label='Next']", "[aria-label='Previous']"],
    "forceReelIdBack": true,
    "restoreScrollOnClose": true,
    "allowScrollSelectors": ["textarea", "input", "[aria-label='Comments']"],
    "videoSelectors": ["video"]
  }
}
```

`allowedPaths` in the real file is longer (login, consent, explore search, individual reels). Do not add `^/[^/]+$`. `/reels` is blocked before that allow list, but the pattern still fights the rest of the rules. Profiles are allowed by the last step.

Back and the settings slider sit on the right edge, midway down, so they do not cover the Instagram header. Back calls the web view's history, or loads home when there is nothing to go back to. The edge-swipe back gesture is on as well. The sheet turns restrictions off (native redirects, hides, and the reel lock pause so you can inspect the real DOM), reloads rules, or reloads the page. The switch is stored in `UserDefaults`. It does not store cookies or your password. A cached remote config is kept only for the same app version. After an update, the bundled JSON is used until a fetch succeeds.

## Workflow failures

| Log | What it means |
| --- | --- |
| Scheme Insta is not configured | `xcodegen` did not write the file `Insta.xcodeproj/xcshareddata/xcschemes/Insta.xcscheme`. The workflow checks that file with `test -f`. Confirm `schemes:` in `project.yml` is named `Insta`. |
| `requires a development team` | Signing was still on. The project sets `CODE_SIGNING_ALLOWED` to NO and the archive step passes the same setting. Don't add `-exportArchive`. |
| `bridge.js` or `fallback-config.json` missing from `unzip -l` | The resource was not in the Copy Bundle Resources phase. Both files are listed under `resources:` in `project.yml`. The log prints the full zip listing just before the grep. |
| IPA grep cannot find `Payload/Insta.app/Info.plist` | The zip was built from the wrong directory. The script `cd`s into `build` and zips `Payload`, so `Payload` is at the root of the archive. |
| Mach-O platform is not `2` | The archive was a simulator build. `-destination 'generic/platform=iOS'` is required. Platform `7` is the simulator. |
| `setup-xcode` cannot find latest-stable | The "List installed Xcode apps" step prints `/Applications/Xcode*.app`. Pin `xcode-version` in the workflow to one of those names (for example `16.4`). |
| Homebrew / XcodeGen failure | The job is `macos-15`. Re-run the workflow. `HOMEBREW_NO_AUTO_UPDATE=1` is set. |

## Known limitations

- Selectors will break when Instagram changes the DOM. That is the normal failure, not a signing failure.
- Hiding posts does not stop the site from requesting them.
- A reel can still advance if Instagram changes the video without a vertical gesture and without a URL change, and the next button has none of the configured labels. Add the label you see in Web Inspector.
- Search that is mislabeled "Explore" can be hidden until you clear `explore.navSelectors`.
- If account search results are `article` nodes on `/explore/`, `gridSelectors` can hide them. Clear that list.
- `/tv/` and live routes are not special-cased. They are allowed because unknown paths are allowed. Say so in `blockedPaths` if you want them redirected.
- The back button and the settings button sit on the right edge. They do not cover the bottom bar or the top-left header.
- Free Apple IDs expire the install every 7 days.
- This is not a privacy tool. You are still using Instagram, logged in, in a web view.

## Test checklist

Check these on a phone after sideloading. Do not treat a green GitHub Action as proof that Instagram's DOM still matches.

- [ ] Log in, including 2FA if you use it. Force-quit Insta, reopen, and confirm you are still logged in.
- [ ] Cold launch opens `https://www.instagram.com/`, not the inbox. The feed posts are gone, including after you scroll, and `/?variant=following` is still stories plus nav. Story rings are visible and open.
- [ ] Open a story and send a reply. The reply composer works. Stories are not stuck in the reel lock.
- [ ] Open the DM inbox, a thread, a group chat, and message requests.
- [ ] Search is visible. Type a username or ID, see results, open the profile.
- [ ] Profile, settings (`/accounts/edit/`), notifications/activity, and log out all work. Create/upload still opens if Instagram's site offers it.
- [ ] The Reels tab is visible, dimmed, and tapping it does nothing. Home, Search, Create, and Profile still work.
- [ ] Open `/reels/` from a typed link, from back/forward, and from a search result. You return home and the page does not bounce.
- [ ] A profile's Reels tab does not open a listing (`/<username>/reels/` goes home).
- [ ] The Explore grid is hidden. Search still works. `/explore/tags/...` goes home.
- [ ] A reel shared in a DM plays.
- [ ] A direct `/reel/<id>/` link plays.
- [ ] In either viewer, swiping up or down does not advance. There is no working next/previous or "up next" control.
- [ ] Like, comment, share, and close still work. After close, DM or profile scrolling works again.
- [ ] A non-Instagram link opens in Safari.
- [ ] Airplane mode on a fresh install still opens with bundled rules (after the first online load, the site itself may not load; the app should show Retry, not an empty rule set).
- [ ] Point the remote URL at a JSON file with a syntax error or `schemaVersion` `999`, tap Reload rules, and confirm the previous rules stay and the sheet explains the rejection.
