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
| `$screen` | `screen(name)` | `name` |
| `$pageview` | web page load / SPA navigation | `url`, `path`, `title`, `referrer`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term` |

## SDK behavior (both SDKs)

- Events go into a persisted queue and are sent in batches: every 30 s, at 20 queued events, and when the app goes
  to the background / the page is hidden. At most 1,000 queued events (oldest dropped first).
- Failed sends retry with exponential backoff (5 s → 5 min); `400`/`401` drop the batch.
- `anon_id`, `user_id`, the queue and the last seen version/build persist across launches.
- A session id is kept in `context.session_id`; a new one starts after 30 minutes in the background / without events.
- `optOut()` stops collection and clears the queue; `optIn()` resumes.
- `reset()` (on logout): new `anon_id`, `user_id` cleared.
- No autocapture of taps/clicks, no screenshots, no IDFA.
