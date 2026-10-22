# Omni SDK wire protocol (v1)

What the Omni SDKs (Swift: `omni-sdk-swift`, JS: npm `omni-growth`) send to Omni Cloud. The cloud turns each event
into Omni's canonical product event (source `omni`) and keeps it until the user's
Mac pulls it (at most 30 days); the Mac keeps it for good.

## Endpoint

```
POST https://api.omnigrowth.app/v1/batch
Content-Type: application/json        (text/plain is accepted too, for navigator.sendBeacon)
```

Body:

```json
{
  "key": "opk_…",
  "sent_at": "2026-10-21T09:00:00.000Z",
  "batch": [
    {
      "uuid": "0192f6c4-…",
      "event": "lesson_completed",
      "ts": "2026-10-21T08:59:58.120Z",
      "anon_id": "a1b2…",
      "user_id": null,
      "properties": { "lesson": 3 },
      "context": {
        "app_version": "1.4.0",
        "build": "52",
        "platform": "ios",
        "device_type": "phone",
        "locale": "ko-KR",
        "os_version": "26.1",
        "device_model": "iPhone17,3",
        "session_id": "0192f6c3-…",
        "sdk": "omni-swift/0.1.0"
      },
      "identity": { "billing_id": "rc_…", "traits": { "email": "a@b.co", "email_consent": true } }
    }
  ]
}
```

- `key`: the app's public write key (`opk_…`), shown to the user by Omni. Write-only: it can add events, never read.
  Also accepted as `?key=` in the URL or `Authorization: Bearer opk_…`.
- `sent_at`: the device clock when the request left. The cloud corrects each `ts` by the difference between its own
  clock and `sent_at` (device clocks drift).
- `batch`: 1–500 events, body ≤ 512 KB.
- `uuid`: unique per event (UUID v4 or v7). Re-sending the same uuid is safe: it's the event's id (`omni:<uuid>`).
- `event`: 1–200 chars. Names starting with `$` are Omni's own (below); everything else is the app's.
- `anon_id`: required. A random id made on first launch and kept on the device; replaced on `reset()`.
- `user_id`: the app's own user id once `identify()` was called, else null.
- `properties`: a flat-ish JSON object (≤ 100 keys, values ≤ 1 KB as JSON each). Optional.
- `context`: all optional. `platform`: `ios` | `ipados` | `android` | `macos` | `web` | `other`.
  `device_type`: `phone` | `tablet` | `desktop` | `other`.
- `identity`: optional, on `$identify` and `$set` only.
  - `billing_id`: the id the billing side knows this person by (RevenueCat app user id, Stripe customer id). This is
    what joins product events to revenue.
  - `traits`: person properties. `email` and `email_consent` (true only after the person agreed to marketing email)
    are the ones Omni uses; anything else is kept as is.

Responses: `200 {"ok":true,"accepted":n}` · `400 {"error":…}` (bad body: don't retry) · `401` bad key (don't retry)
· `413` too large (split and retry) · `429` / `5xx` (retry later with backoff).

## Omni's own events

| event | when | properties |
|---|---|---|
| `$identify` | `identify(userId, traits)` | — (`user_id` and `anon_id` both set: links them) |
| `$set` | `setTraits(...)`, `setBillingId(...)` | — (identity carries it) |
| `$app_installed` | first launch ever | `version`, `build` |
| `$app_updated` | first launch of a new version/build | `version`, `build`, `previous_version`, `previous_build` |
| `$app_opened` | app comes to the foreground (and on cold start) | `from_background` (bool) |
| `$screen` | `screen(name)`; automatically when a screen appears (Swift SDK on iOS/tvOS, option `captureScreens`) | `name`, `auto` (true when captured automatically, false from `.omniScreen(...)`; absent from `screen(name)`) |
| `$delete_user` | `deleteUser()` (account deleted) | — (`anon_id` and `user_id` name who: Omni deletes everything about them) |
| `$pageview` | web page load / SPA navigation | `url`, `path`, `title`, `referrer`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term` |

## Standard events (sent by the app)

Every app sends these with `track` when it has the thing (plain names; `$` names are the SDK's own). They're named
the same in every app, so Omni's funnel, activation and paywall analysis work from day one. The app's own core action
and aha moment come on top, named by its tracking plan in Omni. Payments come from RevenueCat or Stripe, joined by the
billing id, not from events.

| event | when | properties |
|---|---|---|
| `signup` | an account is created (once per person) | `method` |
| `onboarding_step` | each onboarding screen is shown | `step` (1-based), `name` |
| `onboarding_completed` | onboarding finished or skipped | `skipped` |
| `paywall_viewed` | a paywall / upgrade screen is shown | `paywall`, `placement` |
| `purchase_started` | buy / start-trial tapped, before the store sheet | `product_id`, `paywall` |
| `share` | something is shared out of the app | `content`, `channel` |
| `invite_sent` | someone is invited | `channel` |

## SDK behavior (both SDKs)

- Events go into a persisted queue and are sent in batches: every 30 s, at 20 queued events, and when the app goes
  to the background / the page is hidden. At most 1,000 queued events (oldest dropped first).
- Failed sends retry with exponential backoff (5 s → 5 min); `400`/`401` drop the batch.
- `anon_id`, `user_id`, the queue and the last seen version/build persist across launches.
- A session id is kept in `context.session_id`; a new one starts after 30 minutes in the background / without events.
- `optOut()` stops collection and clears the queue; `optIn()` resumes.
- `reset()` (on logout): new `anon_id`, `user_id` cleared.
- `deleteUser()` (on account deletion): sends `$delete_user` with the current ids right away, then resets.
- Swift SDK: `$screen` is sent automatically on iOS/tvOS as screens appear (UIKit view controllers and the SwiftUI views
  they host), named from the screen's type (`WordListViewController` → `WordList`, `PaywallView` → `Paywall`), never
  the same name twice in a row. Option `captureScreens` (default on) turns it off; ignored on macOS.
- No autocapture of taps/clicks, no screenshots, no IDFA.

## Experiments (A/B tests)

Omni runs in-app experiments: the app asks the SDK which variant this device gets and shows that. Omni decides what
runs; the SDK assigns on the device (no network round trip at the moment of asking) and reports exposures.

```
GET https://api.omnigrowth.app/v1/config?key=opk_…      (CORS *, Cache-Control: max-age=60)
```

```json
{
  "experiments": [
    {
      "key": "paywall_headline",
      "variants": [
        { "key": "control", "weight": 50, "payload": {} },
        { "key": "b", "weight": 50, "payload": { "headline": "Remember every word you meet" } }
      ],
      "audience": { "platforms": ["ios", "ipados"], "new_users_since": "2026-10-22T00:00:00.000Z" },
      "winner": null
    }
  ],
  "ttl": 300
}
```

- Only running or decided experiments are listed. An experiment the app asks about that isn't listed → no variant.
- **Assignment** (identical in every SDK): `h = fnv1a32(UTF-8 of "<experiment key>:<bucket id>")` (32-bit FNV-1a:
  offset basis 2166136261, prime 16777619), `bucket = h % 10000`. With `W` = sum of weights, walk the variants in
  order adding `weight * 10000 / W`; the first variant whose running total is greater than `bucket` is the one.
  The division is floating point (64-bit, no rounding: weights 1/1/1 give 3333.33…, 6666.66…, 10000); weights that
  are missing, negative or not numbers count as 0; `W = 0` → no variant. If rounding leaves the last total a hair
  under 10000, bucket 9999 goes to the last variant with a positive weight.
  Test vectors (hash, bucket, chosen variant for 50/50 and 10/30/60): Tests/OmniTests/ExperimentTests.swift; every SDK tests them.
- **Bucket id**: a random UUID made on first launch and kept on the device for good. Unlike `anon_id` it survives
  `reset()` (logging out doesn't move a person to another variant) and is never sent anywhere.
- **Audience** (all present conditions must hold, else not enrolled): `platforms` contains `context.platform`;
  `new_users_since`: the device's first launch (the time `$app_installed` was recorded, kept on the device) is at or
  after it. Devices that ran the app before the SDK had this stored count as old.
- **Winner** set: every device matching `platforms` gets the winning variant (enrolled or not), and no exposures are
  sent: the experiment is over and the app is just being told what to show.
- SDK API: `variant(key) → string | null` and `payload(key) → object | null` (the chosen variant's payload). Null when
  the config isn't loaded yet, the experiment isn't listed, or the device isn't enrolled: the app shows its default.
  The first non-null `variant`/`payload` call for an experiment in a session (no winner) sends `$exposure`. The
  experiments already reported are kept with the session id, so a relaunch / page reload inside the same session
  doesn't repeat them; `reset()` starts a new session, so they're reported again for the new person.
- Config: read from the device's copy at once, fetched at `configure`, on coming to the foreground when older than
  `ttl` seconds (default 300 when absent), and by `loadExperiments(timeout)` (async; resolves when fetched or after
  the timeout, default 2 s; for screens shown right at first launch such as onboarding). `loadExperiments` joins a
  fetch already under way, and resolves at once when the copy is younger than `ttl`. A failed fetch (network error,
  non-2xx, a body that isn't a config) keeps the last copy. Kept on disk. An experiment in a shape the SDK can't read
  is skipped, not the whole config.
- Web (`omni-growth`): same, with `localStorage` for the bucket id, the first visit's time and the copy; "coming to
  the foreground" is the page becoming visible again.

## Push notifications

Omni sends push to the app's users (APNs for iOS, FCM for Android) from the founder's Mac with the founder's own
credentials. The SDK only reports tokens, permission and opens.

- `setPushToken(token)`: Swift takes the APNs device token `Data` (hex-encoded); Android/JS take a string (FCM token).
  Sends `$push_token` when the token, provider or environment changed, or 7 days after the last one, and again right
  after `reset()` (the token moves to the new anonymous id, so pushes follow whoever is signed in on the device).
  FCM tokens are sent with `environment: "production"`. Swift: a new token is followed by the last `$push_permission`
  again, since Omni keeps the permission with the token.
- `$push_permission` `{ status }`: `authorized` | `denied` | `provisional` | `ephemeral` | `not_determined`. Swift
  reads it at configure and on every foreground and sends it when it changed. Android: `authorized` / `denied` from
  `NotificationManagerCompat.areNotificationsEnabled()`, same moments.
- Omni's pushes carry `"omni": { "message_id": "m_…", "url": "<optional deep link>" }` (APNs: a top-level key of the
  payload next to `aps`; FCM: data keys `omni_message_id`, `omni_url`). `trackPushOpened(userInfo | extras)` sends
  `$push_opened` `{ message_id }` when the payload is Omni's and returns the deep link (or null). Android SDK also does
  this itself for the launch intent of an activity opened from a notification.

## Attribution (where people came from)

- Web: on the first page view ever, the SDK keeps the first touch and sends `$attribution` once:
  `{ source: "web", utm_source, utm_medium, utm_campaign, utm_content, utm_term, ct, referrer, landing_path }`
  (`referrer` is the referring site's host, left out when it's the same site; `landing_path` the first page's path;
  parameters that aren't in the URL are left out). If collection is off then (`optOut()` before or right after
  `init`), it's kept and sent once collection is allowed. Browsers that ran an older SDK version have no first
  visit to report and never send one. Omni's links to a website carry `utm_source=<channel>&utm_campaign=<ct>`.
- Android: on first launch the SDK reads the Play Install Referrer and sends `$attribution`
  `{ source: "play_install_referrer", referrer, utm_source, utm_medium, utm_campaign, utm_content, click_ts,
  install_ts }` once (Omni's Play links carry `utm_campaign=<ct>`).
- iOS: Apple doesn't hand the campaign to the app, so there's nothing automatic. Downloads per post come from App
  Store Connect (campaign tokens); people come from the standard event `acquisition_source` (the app asks "Where did
  you hear about us?" once).

| event | when | properties |
|---|---|---|
| `$exposure` | first `variant`/`payload` of a running experiment in a session | `experiment`, `variant` |
| `$push_token` | push token known / changed / weekly | `token`, `provider` (`apns` \| `fcm`), `environment` (`production` \| `sandbox`), `topic` (iOS bundle id) |
| `$push_permission` | permission seen to change | `status` |
| `$push_opened` | an Omni push was opened | `message_id` |
| `$attribution` | once per install (web, Android) | as above |
| `acquisition_source` (standard, sent by the app) | the person answered "where did you hear about us?" | `source` (`instagram` \| `tiktok` \| `threads` \| `youtube` \| `friend` \| `app_store_search` \| `web` \| `other`), `detail` |

## Email

The app passes `email` and `email_consent` (true only after the person agreed to marketing email) as traits. Omni
emails only people with consent, from the founder's own verified domain, through Omni Cloud; every email carries a
one-click unsubscribe link that sets `email_consent` to false in Omni. Nothing for the SDK to do beyond the traits.
