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

## Deploy & first full backfill

### 0. Reference the plugin from Earss

The plugin is a normal `earss_source_*` OTP app. During **development** use a
path dep; for **releases/Docker/Nix** prefer a pinned git ref (path deps are
not available inside container/derivation build contexts):

```bash
# dev (this repo layout)
EARSS_SOURCE_PLUGINS=path:../../earss_source_weread

# build server / CI — pin a commit (floating @main changes the deps hash)
EARSS_SOURCE_PLUGINS=git:https://github.com/<you>/earss_source_weread@<commit-sha>
```

After changing `EARSS_SOURCE_PLUGINS`: `mix deps.get && mix compile`.

### 1. Development machine (fastest smoke test)

```bash
cd path/to/earss
cat >> earss.env <<'EOF'
EARSS_SOURCE_PLUGINS=path:../../earss_source_weread
EARSS_WEREAD_COOKIE_CLOUD_URL=http://<cookie-cloud-host>:4000
EARSS_WEREAD_COOKIE_CLOUD_UUID=<uuid>
EARSS_WEREAD_COOKIE_CLOUD_TOKEN=<server-password>
EARSS_WEREAD_BACKFILL_PAGES=5        # first pull ≈ 100 articles per 公众号
EOF
mix deps.get && mix compile
iex -S mix
```

```elixir
Earss.Source.Registry.list_adapters() |> Enum.map(& &1.id)   # => ["native", "weread"]

# shelf mode: everything on your bookshelf, backfilled
{:ok, sub} = Earss.Reader.subscribe(u, %{link: "earss://weread/shelf", refresh: true})

# or single account: targeted backfill
{:ok, sub} = Earss.Reader.subscribe(u, %{link: "earss://weread/mp/MP_WXS_3528995129", refresh: true})

Earss.Feeds.list_entries(sub.feed) |> Enum.map(& &1.title)   # backfilled history
```

`refresh: true` triggers the first fetch synchronously — that is the full
backfill (shelf = N 公众号 × backfill_pages; single = 1 × backfill_pages).

### 2. Docker Compose

Build context must fetch the plugin by git ref, not path:

```yaml
# docker-compose.yml (earss root repo)
# Build passes EARSS_SOURCE_PLUGINS to `mix deps.get` inside the image.
# Set these under environment: for the earss service:
#   EARSS_WEREAD_COOKIE_CLOUD_URL / _UUID / _TOKEN
#   EARSS_WEREAD_BACKFILL_PAGES=5
```

See earss `docs/docker.md` for the base workflow; only the plugin env vars and
the `EARSS_SOURCE_PLUGINS` build arg change.

### 3. NixOS (homeserver — recommended)

From the **host** flake: build the earss package with the plugin pinned, then
feed the weread env via `services.earss.environment` (or a systemd drop-in):

```nix
# host flake
earssPkg = earss.lib.mkEarss {
  inherit pkgs;
  sourcePlugins = "git:https://github.com/<you>/earss_source_weread@<commit>";
  mixDepsHash = "sha256-…";          # obtain via `nix build` after editing plugins
};

services.earss = {
  enable = true;
  package = earssPkg;
  # …
  environment = {
    EARSS_WEREAD_COOKIE_CLOUD_URL = "http://<cookie-cloud-host>:4000";
    EARSS_WEREAD_COOKIE_CLOUD_UUID = "<uuid>";
    EARSS_WEREAD_COOKIE_CLOUD_TOKEN = "<server-password>";
    EARSS_WEREAD_BACKFILL_PAGES = "5";
  };
};
```

Pin the plugin **commit** (not `@main`) or the fixed-output deps hash breaks
when the branch moves; refresh `mixDepsHash` after any plugin change (see
earss `docs/nixos.md`).

### 4. Mix release + systemd

```bash
export EARSS_SOURCE_PLUGINS='git:https://github.com/<you>/earss_source_weread@<commit>'
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release
# on the server: Runtime env via .env / systemd EnvironmentFile — same keys as above
```

### First-full-history tuning

| Goal | Setting |
|------|---------|
| 20 articles per 公众号 | `EARSS_WEREAD_BACKFILL_PAGES=1` |
| ~100 (default recommendation) | `EARSS_WEREAD_BACKFILL_PAGES=5` |
| ~200 (deep) | `EARSS_WEREAD_BACKFILL_PAGES=10` |

Notes:

* Backfill happens **only on the first poll** of a feed (empty cursor);
  afterwards each poll is one list request per 公众号 plus public content
  fetches for new items only.
* Each backfill page is one weread request per 公众号. With the shelf route
  that is `#公众号 × pages` requests on first pull — keep
  `EARSS_WEREAD_REQUEST_INTERVAL_MS >= 1000` and ensure the browser cookie is
  fresh before a big first pull (WeRead kicks login on bursts).
* Bodies come from the **public** mp.weixin.qq.com URLs (no WeRead quota), so
  deep first pulls are safe from WeRead's perspective.

## Legal

Scraping 微信读书 / 微信公众号 is subject to WeChat's terms of service and
WeRead's rate limits; using your own logged-in account and a polite interval
is your responsibility as operator.

## Test

```bash
mix deps.get && mix test
```

Pure unit tests with Bypass stubs — no PostgreSQL, no live WeRead account.