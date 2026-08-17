# earss_source_weread

Earss source adapter for **微信读书 (WeRead)** — the articles of the 公众号
(WeChat official accounts) you subscribe to on the WeRead bookshelf.

Earss integration: `earss://weread/...` routes. Implements
`Earss.Source.Adapter` (contract `packages/earss_source`, `adapter_api = 1`)
and depends **only** on `earss_source` — never on Earss internals (C2).

## Routes

| Route | Description | Example |
|-------|-------------|---------|
| `weread/shelf` | 书架合流 — latest article of **every** 公众号 on your bookshelf, merged into one feed (`author` = 公众号名) | `earss://weread/shelf` |
| `weread/mp/:bookId` | A single 公众号's latest article. `bookId` accepts `MP_WXS_<数字>` or bare digits (auto-prefixed) | `earss://weread/mp/MP_WXS_3528995129` |

`source_url` is stable per logical route (bookId canonicalized once), so OPML
round-trips and multi-user subscriptions keep working.

## How it works (WeRead API reality, 2026-08 probing)

The article-list endpoint `/web/mp/articles` is **alive again** — the
we-mp-rss project reported `-2041` (deprecated) for it, but real-world
probing on 2026-08-17 with a logged-in cookie returns the recent article
list, **latest first**. Probe results:

| Endpoint | Result |
|----------|--------|
| `GET /web/shelf/sync?userVid=&synckey=0` | bookshelf; 公众号 = `bookId` starting with `MP_WXS_`; **`userVid` must be empty** — non-empty triggers `-2012` |
| `GET /web/mp/articles?bookId=MP_WXS_xxx&offset=0` | **recent article list, ~20 items per page, latest first, paginated via `offset`** (`count` is ignored). Probing pulled 80+ contiguous items across offset 0/20/40/60 — history depth is capped only by your backfill setting |
| `GET /web/mp/content?reviewId=...` | full article HTML; body parsed from `#js_content` (`data-src` images promoted, `http://` URLs folded to `https://`) — **legacy path** (cookie + rate-limited) |

Each list item carries everything an entry needs: `reviewId`, `originalId`
(= the mp.weixin.qq.com article token, so the original URL needs no
derivation), `title`, `mp_name`, `content` (digest), `time` (real publish
unix seconds), `pic_url`, `readNum`, `likeNum`.

**Content path (two-channel):**

1. **Public first** — the body is fetched from the public
   `https://mp.weixin.qq.com/s/<originalId>` URL with **no WeRead cookie**
   (`EarssSourceWeread.Public`). This is safe against WeRead's rate-limits and
   is the default.
2. Articles whose public page has no extractable body (deleted/paid content)
   degrade gracefully to the digest (`summary`) with a clickable original
   link.

**Depth:** the endpoint is **paginated** (`offset` = items already loaded,
page size fixed at 20). History is limited only by how many pages you
backfill — and by how politely you ask (WeRead rate-limits; see below).

**Rate-limit safety:** WeRead answers `-2012` (登录超时) and kicks the login
state after bursts of rapid requests (observed after ~30 requests with
1–2s gaps). Keep intervals conservative:

* `EARSS_WEREAD_BACKFILL_PAGES` defaults to **1** (20 articles per 公众号 on
  the first poll only; later polls are a single list request per 公众号) —
  raise to 2–5 (40–100 articles) only if you accept the first-pull request
  burst, then keep `EARSS_WEREAD_REQUEST_INTERVAL_MS >= 1000`.
* `EARSS_WEREAD_FETCH_CONTENT` defaults to **false**; when enabled keep
  `EARSS_WEREAD_CONTENT_INTERVAL_MS >= 2000`.

The adapter does **list incremental polling**: each poll fetches the list per
公众号, compares the newest `reviewId` against the persisted cursor
(`feed.adapter_cursor.seen = %{bookId => latestReviewId}`), and emits entries
only for newer items. First poll = backfill of `BACKFILL_PAGES` pages.

## Configuration

Cookies (either static or CookieCloud — same pattern as earss_source_zhihu):

| Env | Meaning | Default |
|-----|---------|---------|
| `EARSS_WEREAD_COOKIES` | full browser `Cookie` header string (wins if set) | — |
| `EARSS_WEREAD_COOKIE_CLOUD_URL` | self-hosted cookie_cloud_server base URL | — |
| `EARSS_WEREAD_COOKIE_CLOUD_UUID` | CookieCloud uuid | — |
| `EARSS_WEREAD_COOKIE_CLOUD_TOKEN` | Bearer token | — |
| `EARSS_WEREAD_COOKIE_CLOUD_DOMAIN` | domain filter | `weread.qq.com` |
| `EARSS_WEREAD_COOKIE_CLOUD_CACHE_MS` | CookieCloud cache TTL | `300000` |

Cookie read: `GET {URL}/get/{UUID}?format=header&domain={domain}` with
`Authorization: Bearer {TOKEN}`. The cookie must contain `wr_vid` (plus
usually `wr_skey`, `wr_gid`, `wr_fp`).

Fetch behaviour:

| Env | Meaning | Default |
|-----|---------|---------|
| `EARSS_WEREAD_FETCH_CONTENT` | pull full article HTML from the **public** mp.weixin.qq.com URL (no cookie, safe) | `true` |
| `EARSS_WEREAD_BACKFILL_PAGES` | pages of history backfilled on a **first** poll (1 ≈ 20 articles; raise for deeper first pull, e.g. 5 ≈ 100) | `3` |
| `EARSS_WEREAD_REQUEST_INTERVAL_MS` | pause between weread list/shelf requests (keep ≥ 1000) | `1000` |
| `EARSS_WEREAD_PUBLIC_CONTENT_INTERVAL_MS` | pause between public content fetches | `200` |
| `EARSS_WEREAD_SHELF_MAX_MPS` | cap 公众号 processed per shelf poll (`0` = unlimited) | `0` |
| `EARSS_WEREAD_SHELF_TITLE` | shelf feed title | `微信读书书架公众号` |
| `EARSS_WEREAD_HTTP_TIMEOUT_MS` | request timeout | `20000` |
| `EARSS_WEREAD_BASE_URL` | weread API base (test/proxy override) | `https://weread.qq.com` |
| `EARSS_WEREAD_PUBLIC_BASE_URL` | public article base (test/proxy override) | `https://mp.weixin.qq.com` |

> ⚠️ **Rate limits**: WeRead is strict on the content endpoint. Keep
> `EARSS_WEREAD_CONTENT_INTERVAL_MS >= 2000`. With `FETCH_CONTENT=false`
> (default) each poll is only shelf + one lightweight cover call per 公众号 —
> safe for the 60-min default refresh.

Auth / 风控 errors (`errCode -2012 / -2010 / -2041`) are surfaced as
`{:error, {:weread_auth, code}}`; when using CookieCloud the cached cookie is
invalidated and one retry with a fresh cookie is attempted first.

## Install & subscribe

```bash
cd /path/to/earss
# in earss.env:
# EARSS_SOURCE_PLUGINS=path:../earss_source_weread
# EARSS_WEREAD_COOKIE_CLOUD_URL=http://127.0.0.1:4000
# EARSS_WEREAD_COOKIE_CLOUD_UUID=<uuid>
# EARSS_WEREAD_COOKIE_CLOUD_TOKEN=<server password>
mix deps.get && mix compile
iex -S mix
```

```elixir
Earss.Source.Registry.list_adapters() |> Enum.map(& &1.id)
# => ["native", "weread"]

{:ok, sub} =
  Earss.Reader.subscribe(u, %{
    link: "earss://weread/shelf",   # or earss://weread/mp/MP_WXS_xxx
    refresh: true
  })

Earss.Feeds.list_entries(sub.feed) |> Enum.map(& &1.title) |> Enum.take(5)
```

> First shelf poll enumerates every 公众号; with `FETCH_CONTENT=true` the first
> run can take a while (N 公众号 × 2s). Cap it with
> `EARSS_WEREAD_SHELF_MAX_MPS` or leave content fetch off.

## Legal

Scraping 微信读书 / 微信公众号 is subject to WeChat's terms of service and
WeRead's rate limits; using your own logged-in account and a polite interval
is your responsibility as operator.

## Test

```bash
mix deps.get && mix test
```

Pure unit tests with Bypass stubs — no PostgreSQL, no live WeRead account.