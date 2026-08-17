defmodule EarssSourceWeread.Config do
  @moduledoc """
  Operator configuration for the WeRead (微信读书) adapter.

  Prefer process environment (also loaded from host `earss.env`).

  ## Cookies (either static **or** CookieCloud)

    * `EARSS_WEREAD_COOKIES` — static browser Cookie string (wins if set)
    * `EARSS_WEREAD_COOKIE_CLOUD_URL` — base URL, e.g. `http://127.0.0.1:4000`
    * `EARSS_WEREAD_COOKIE_CLOUD_UUID` — CookieCloud uuid
    * `EARSS_WEREAD_COOKIE_CLOUD_TOKEN` — Bearer token (`COOKIE_CLOUD_SERVER_PASSWORD`)
    * `EARSS_WEREAD_COOKIE_CLOUD_DOMAIN` — default `weread.qq.com`
    * `EARSS_WEREAD_COOKIE_CLOUD_CACHE_MS` — cache TTL, default `300000` (5 min)

  CookieCloud admin export used:

      GET {URL}/get/{UUID}?format=header&domain={domain}
      Authorization: Bearer {TOKEN}

  Login cookies for weread.qq.com need at least `wr_vid` (and ideally `wr_skey`,
  `wr_gid`, `wr_fp`). See `required_cookie_keys/0` / `validate_cookie/1`.

  ## Fetch behaviour

    * `EARSS_WEREAD_FETCH_CONTENT` — pull full article HTML. Default **`true`**:
      bodies are fetched from the **public** mp.weixin.qq.com URL (no WeRead
      cookie), so it is safe to enable by default.
    * `EARSS_WEREAD_BACKFILL_PAGES` — pages of history backfilled on a **first**
      poll (each page ≈ 20 articles). Default `3` (≈60 per 公众号); raise for a
      deeper first pull (5 ≈ 100, 10 ≈ 200) — the list endpoint is relatively
      safe and bodies are public. Each page is one weread request per 公众号, on
      first poll only.
    * `EARSS_WEREAD_REQUEST_INTERVAL_MS` — pause between weread list/shelf
      requests, default `1000`. Keep >= 1000 on deep backfills (WeRead kicks
      the login after request bursts).
    * `EARSS_WEREAD_PUBLIC_CONTENT_INTERVAL_MS` — pause between **public**
      content fetches (mp.weixin.qq.com, no cookie). Default `200`; raise if
      WeChat answers with a captcha/风险页.
    * `EARSS_WEREAD_SHELF_MAX_MPS` — cap the number of 公众号 processed per
      shelf poll (default `0` = unlimited). Useful to bound first-pull time.
    * `EARSS_WEREAD_SHELF_TITLE` — feed title for the shelf route
      (default `微信读书书架公众号`).
    * `EARSS_WEREAD_HTTP_TIMEOUT_MS` — default `20000`

  Application env (`config :earss_source_weread, ...`) overrides are also read.
  """

  alias EarssSourceWeread.CookieCloud

  @default_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

  # Keys considered necessary for the weread.qq.com web APIs.
  @required_cookie_keys ["wr_vid"]

  @doc "Cookie names required/useful for weread.qq.com web APIs."
  @spec required_cookie_keys() :: [String.t()]
  def required_cookie_keys, do: @required_cookie_keys

  @doc """
  Resolve Cookie header string.

  1. Static `EARSS_WEREAD_COOKIES` / app env `:cookies`
  2. Else CookieCloud admin `format=header` when URL+UUID+TOKEN are set

  Options: `:force` — refresh CookieCloud cache.
  """
  @spec cookies(keyword()) :: String.t() | nil
  def cookies(opts \\ []) do
    case static_cookies() do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        case CookieCloud.fetch(opts) do
          {:ok, s} -> s
          {:error, _} -> nil
        end
    end
  end

  @doc """
  Validate a cookie header string has the required weread keys.

  Returns `{:ok, cookie}` when every `required_cookie_keys/0` entry is present,
  else `{:error, {:missing_cookie, key}}`.
  """
  @spec validate_cookie(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_cookie(cookie) when is_binary(cookie) and cookie != "" do
    missing =
      Enum.reject(@required_cookie_keys, fn key -> extract_cookie(cookie, key) != nil end)

    case missing do
      [] -> {:ok, cookie}
      [key | _] -> {:error, {:missing_cookie, key}}
    end
  end

  def validate_cookie(_), do: {:error, :missing_cookies}

  @spec static_cookies() :: String.t() | nil
  def static_cookies do
    case app_get(:cookies) || System.get_env("EARSS_WEREAD_COOKIES") do
      nil -> nil
      "" -> nil
      s when is_binary(s) -> String.trim(s)
      _ -> nil
    end
  end

  @spec cookie_source() :: :static | :cookie_cloud | :none
  def cookie_source do
    cond do
      present?(static_cookies()) -> :static
      match?({:ok, _}, CookieCloud.config()) -> :cookie_cloud
      true -> :none
    end
  end

  @spec cookie_cloud_base_url() :: String.t() | nil
  def cookie_cloud_base_url,
    do: trim_env(app_get(:cookie_cloud_url) || System.get_env("EARSS_WEREAD_COOKIE_CLOUD_URL"))

  @spec cookie_cloud_uuid() :: String.t() | nil
  def cookie_cloud_uuid,
    do: trim_env(app_get(:cookie_cloud_uuid) || System.get_env("EARSS_WEREAD_COOKIE_CLOUD_UUID"))

  @spec cookie_cloud_token() :: String.t() | nil
  def cookie_cloud_token,
    do:
      trim_env(app_get(:cookie_cloud_token) || System.get_env("EARSS_WEREAD_COOKIE_CLOUD_TOKEN"))

  @spec cookie_cloud_domain() :: String.t()
  def cookie_cloud_domain do
    case trim_env(
           app_get(:cookie_cloud_domain) || System.get_env("EARSS_WEREAD_COOKIE_CLOUD_DOMAIN")
         ) do
      nil -> "weread.qq.com"
      d -> d
    end
  end

  @spec cookie_cloud_cache_ms() :: pos_integer()
  def cookie_cloud_cache_ms do
    parse_pos_int(
      app_get(:cookie_cloud_cache_ms) || System.get_env("EARSS_WEREAD_COOKIE_CLOUD_CACHE_MS"),
      300_000
    )
  end

  @spec user_agent() :: String.t()
  def user_agent do
    case app_get(:user_agent) || System.get_env("EARSS_WEREAD_USER_AGENT") do
      nil -> @default_ua
      "" -> @default_ua
      s when is_binary(s) -> s
      _ -> @default_ua
    end
  end

  @spec http_timeout_ms() :: pos_integer()
  def http_timeout_ms do
    parse_pos_int(
      app_get(:http_timeout_ms) || System.get_env("EARSS_WEREAD_HTTP_TIMEOUT_MS"),
      20_000
    )
  end

  @doc "Fetch full article content? Default `true` — bodies come from the public mp.weixin.qq.com URL (no WeRead cookie)."
  @spec fetch_content?() :: boolean()
  def fetch_content? do
    env_val = app_get(:fetch_content) || System.get_env("EARSS_WEREAD_FETCH_CONTENT")
    truthy?(env_val, true)
  end

  @doc "Pause between **public** content fetches (mp.weixin.qq.com, no cookie)."
  @spec public_content_interval_ms() :: non_neg_integer()
  def public_content_interval_ms do
    parse_non_neg_int(
      app_get(:public_content_interval_ms) ||
        System.get_env("EARSS_WEREAD_PUBLIC_CONTENT_INTERVAL_MS"),
      200
    )
  end

  @doc "Pause between weread list/shelf requests (ms)."
  @spec request_interval_ms() :: non_neg_integer()
  def request_interval_ms do
    parse_non_neg_int(
      app_get(:request_interval_ms) || System.get_env("EARSS_WEREAD_REQUEST_INTERVAL_MS"),
      1_000
    )
  end

  @doc "Max 公众号 processed per shelf poll. `0` = unlimited."
  @spec shelf_max_mps() :: non_neg_integer()
  def shelf_max_mps do
    parse_non_neg_int(
      app_get(:shelf_max_mps) || System.get_env("EARSS_WEREAD_SHELF_MAX_MPS"),
      0
    )
  end

  @doc "Pages of history backfilled on a first poll (0 = none, 3 ≈ 60 articles)."
  @spec backfill_pages() :: non_neg_integer()
  def backfill_pages do
    parse_non_neg_int(
      app_get(:backfill_pages) || System.get_env("EARSS_WEREAD_BACKFILL_PAGES"),
      3
    )
  end

  @doc "User-Agent for public (mp.weixin.qq.com) fetches — plain browser UA, no cookie."
  @spec public_ua() :: String.t()
  def public_ua do
    case trim_env(app_get(:public_ua) || System.get_env("EARSS_WEREAD_PUBLIC_UA")) do
      nil -> @default_ua
      ua -> ua
    end
  end

  @doc "Feed title for the shelf route."
  @spec shelf_title() :: String.t()
  def shelf_title do
    case trim_env(app_get(:shelf_title) || System.get_env("EARSS_WEREAD_SHELF_TITLE")) do
      nil -> "微信读书书架公众号"
      t -> t
    end
  end

  @doc """
  Base URL for the **public** article fetch (mp.weixin.qq.com). Overridable
  for tests/proxies via `EARSS_WEREAD_PUBLIC_BASE_URL`.
  """
  @spec public_base_url() :: String.t() | nil
  def public_base_url do
    trim_env(app_get(:public_base_url) || System.get_env("EARSS_WEREAD_PUBLIC_BASE_URL"))
  end

  @spec base_url() :: String.t()
  def base_url do
    case trim_env(app_get(:base_url) || System.get_env("EARSS_WEREAD_BASE_URL")) do
      nil -> "https://weread.qq.com"
      url -> String.trim_trailing(url, "/")
    end
  end

  @doc "Extract one cookie key value from a Cookie header string."
  @spec extract_cookie(String.t(), String.t()) :: String.t() | nil
  def extract_cookie(cookie_str, key) when is_binary(cookie_str) and is_binary(key) do
    cookie_str
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [^key, value] when value != "" -> value
        _ -> nil
      end
    end)
  end

  ## Env helpers (same semantics as earss_source_zhihu)

  defp parse_pos_int(nil, default), do: default
  defp parse_pos_int(n, _default) when is_integer(n) and n > 0, do: n

  defp parse_pos_int(s, default) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_pos_int(_, default), do: default

  defp parse_non_neg_int(nil, default), do: default
  defp parse_non_neg_int(n, _default) when is_integer(n) and n >= 0, do: n

  defp parse_non_neg_int(s, default) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_non_neg_int(_, default), do: default

  defp trim_env(nil), do: nil
  defp trim_env(""), do: nil
  defp trim_env(s) when is_binary(s), do: String.trim(s)
  defp trim_env(_), do: nil

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  # nil env for boolean → default; "0"/"false"/"no"/"off" → false; else true.
  defp truthy?(nil, default), do: default
  defp truthy?(v, _default) when is_boolean(v), do: v

  defp truthy?(v, _default) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      s when s in ["0", "false", "no", "off", ""] -> false
      _ -> true
    end
  end

  defp truthy?(_, default), do: default

  defp app_get(key) do
    Application.get_env(:earss_source_weread, key)
  end
end
