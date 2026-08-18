defmodule EarssSourceWeread.Client do
  @moduledoc """
  HTTP client for `weread.qq.com` web JSON APIs with login Cookie.

  Cookie comes from static `EARSS_WEREAD_COOKIES` **or** CookieCloud
  (`EARSS_WEREAD_COOKIE_CLOUD_*`).

  WeRead returns **HTTP 200 with a business `errCode`** for auth/风控 errors;
  known codes (see `auth_codes/0`):

    * `-2012` — 登录态失效 / cookie 过期
    * `-2010` — 风控 / token 无效
    * `-2041` — 接口废弃 / 风控 (e.g. old `/web/mp/articles`)

  On those, when using CookieCloud we invalidate the cached cookie and retry
  once with a fresh one (same pattern as earss_source_zhihu).

  ## Endpoints used

    * `GET /web/shelf/sync?userVid=&synckey=0` — shelf (公众号 = `MP_WXS_*`)
    * `GET /api/mp/cover?bookId=` — latest article of a 公众号 (new-style)
    * `GET /web/mp/content?reviewId=` — article HTML body
  """

  require Logger

  alias Earss.Source.Politeness
  alias EarssSourceWeread.Config
  alias EarssSourceWeread.CookieCloud

  @auth_codes [-2012, -2010, -2041]

  @doc "WeRead business error codes that mean auth / 风控, retry with fresh cookie."
  @spec auth_codes() :: [integer()]
  def auth_codes, do: @auth_codes

  @doc """
  GET JSON from a WeRead web path, e.g. `"/api/mp/cover"`.

  Options:

    * `:query` — map of query params
    * `:referer` — Referer header (defaults to `https://weread.qq.com/`)
    * `:accept` — Accept header (default JSON)
    * `:timeout` — ms (default from Config)
    * `:decode_html` — return raw body string instead of JSON
  """
  @spec get_json(String.t(), keyword()) ::
          {:ok, map() | String.t()}
          | {:error, term()}
  def get_json(api_path, opts \\ []) when is_binary(api_path) do
    force_cookie? = Keyword.get(opts, :force_cookie_refresh, false)

    with {:ok, cookie} <- resolve_cookie(force: force_cookie?),
         {:ok, headers} <- build_headers(cookie, opts) do
      do_request(api_path, headers, opts, cookie_retried?: force_cookie?)
    end
  end

  ## request

  defp do_request(api_path, headers, opts, cookie_retried?: retried?) do
    url = Config.base_url() <> api_path
    timeout = Keyword.get(opts, :timeout, Config.http_timeout_ms())
    query = Keyword.get(opts, :query, %{})
    decode_html? = Keyword.get(opts, :decode_html, false)

    case Req.get(url,
           headers: headers,
           params: query,
           receive_timeout: timeout,
           redirect: true,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        if decode_html? do
          decode_html(body, api_path)
        else
          decode_json(body, api_path)
        end

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        maybe_retry_fresh_cookie(api_path, opts, retried?)

      {:ok, %Req.Response{status: status, headers: resp_headers}}
      when status in [429, 503] ->
        secs = Politeness.retry_after_seconds(resp_headers)
        {:error, {:rate_limited, secs || status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        Logger.warning("weread request failed #{url}: #{inspect(exception)}")
        {:error, {:http, exception}}
    end
  end

  defp decode_html(body, _api_path) when is_binary(body) do
    # WeRead may still answer an HTML endpoint with a JSON error body.
    trimmed = String.trim(body)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(body) do
        {:ok, map} when is_map(map) ->
          case err_code(map) do
            0 -> {:ok, body}
            code when code in @auth_codes -> {:error, {:weread_auth, code}}
            code -> {:error, {:weread, code}}
          end

        _ ->
          {:ok, body}
      end
    else
      {:ok, body}
    end
  end

  defp decode_html(_, _), do: {:error, :invalid_body}

  defp decode_json(body, api_path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        case err_code(map) do
          0 ->
            {:ok, map}

          code when code in @auth_codes ->
            Logger.warning("weread #{api_path} auth/风控 errCode=#{code}")

            if captcha?(map) do
              Logger.warning(
                "weread requires a CAPTCHA (人机验证) at #{api_path} — resolve it in a browser " <>
                  "(weread.qq.com), CookieCloud will sync the new cookies"
              )

              {:error, {:weread_captcha, code}}
            else
              {:error, {:weread_auth, code}}
            end

          code ->
            {:error, {:weread, code}}
        end

      {:ok, _} ->
        {:error, :invalid_json}

      {:error, reason} ->
        if is_binary(body) and captcha_in_body?(body) do
          Logger.warning(
            "weread #{api_path} answered a CAPTCHA page — resolve it in a browser " <>
              "(weread.qq.com), CookieCloud will sync the new cookies"
          )

          {:error, {:weread_captcha, -2041}}
        else
          {:error, {:json, reason}}
        end
    end
  end

  defp decode_json(_, _), do: {:error, :invalid_json}

  defp captcha_in_body?(body) do
    String.contains?(body, "tc-captcha") or
      String.contains?(body, "captcha.gtimg.com") or
      String.contains?(body, "tcaptcha") or
      String.contains?(body, "TCaptcha")
  end

  ## auth retry (CookieCloud only)

  defp maybe_retry_fresh_cookie(api_path, opts, retried?) do
    if not retried? and Config.cookie_source() == :cookie_cloud do
      CookieCloud.invalidate()

      with {:ok, cookie} <- resolve_cookie(force: true),
           {:ok, headers} <- build_headers(cookie, opts) do
        do_request(api_path, headers, opts, cookie_retried?: true)
      else
        {:error, _} = err -> err
      end
    else
      {:error, :auth_rejected}
    end
  end

  ## cookie / headers

  defp resolve_cookie(opts) do
    case Config.cookies(opts) do
      nil ->
        {:error, :missing_cookies}

      cookie ->
        case Config.validate_cookie(cookie) do
          {:ok, c} -> {:ok, c}
          {:error, _} = err -> err
        end
    end
  end

  defp build_headers(cookie, opts) do
    headers = [
      {"cookie", cookie},
      {"user-agent", Config.user_agent()},
      {"accept", Keyword.get(opts, :accept, "application/json, text/plain, */*")},
      {"accept-language", "zh-CN,zh;q=0.9,en;q=0.8"},
      {"origin", Config.base_url()},
      {"referer", Keyword.get(opts, :referer, "https://weread.qq.com/")}
    ]

    {:ok, headers}
  end

  # -2041 (and friends) can carry a Tencent TCaptcha challenge page in the
  # response rather than a plain error object.
  defp captcha?(map) do
    err = inspect(map)

    String.contains?(err, "tc-captcha") or
      String.contains?(err, "captcha.gtimg.com") or
      String.contains?(err, "tcaptcha") or
      String.contains?(err, "TCaptcha") or
      String.contains?(err, "验证码")
  end

  defp err_code(map) do
    case Map.get(map, "errCode") || Map.get(map, "errcode") do
      nil -> 0
      "" -> 0
      code when is_integer(code) -> code
      code when is_binary(code) -> String.to_integer(code)
      _ -> 0
    end
  end
end
