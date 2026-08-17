defmodule EarssSourceWeread.Public do
  @moduledoc """
  Fetch the **public** original article from mp.weixin.qq.com using the
  article token (`originalId` / `reviewId` trailing segment).

  No WeRead cookie is needed — mp.weixin.qq.com serves the article publicly.
  This is the **preferred** content path: it does not consume the WeRead
  (weread.qq.com) request budget at all, so it is far safer against WeRead's
  rate-limits than `/web/mp/content`.

  ## Caveats

  WeChat sometimes answers with a captcha / risk page instead of the article
  (rare for `mp.weixin.qq.com/s/<token>` article URLs). `fetch/1` detects
  that and returns `{:error, :blocked}` so the caller can degrade gracefully.
  """

  alias EarssSourceWeread.{Config, Extract}

  @doc "Fetch the article body from a full public URL (mp.weixin.qq.com long/short link)."
  @spec fetch_url(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_url(url) when is_binary(url) and url != "" do
    headers = [{"user-agent", Config.public_ua()}]

    case Req.get(url,
           headers: headers,
           retry: false,
           redirect: true,
           receive_timeout: Config.http_timeout_ms(),
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body = body || ""

        cond do
          blocked?(body) ->
            {:error, :blocked}

          true ->
            case Extract.js_content(body) do
              {:ok, html} -> {:ok, html}
              err -> err
            end
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:http, exception}}
    end
  end

  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(original_id) when is_binary(original_id) and original_id != "" do
    base =
      case Config.public_base_url() do
        nil -> "https://mp.weixin.qq.com"
        url -> String.trim_trailing(url, "/")
      end

    fetch_url(base <> "/s/#{original_id}")
  end

  def fetch(_), do: {:error, :invalid_token}

  # Captcha / environment / risk-control interstitial markers.
  defp blocked?(body) do
    String.contains?(body, "验证码") or
      String.contains?(body, "访问过于频繁") or
      String.contains?(body, "环境异常") or
      String.contains?(body, "verify.tool.qq.com") or
      String.contains?(body, "wssecurity") or
      String.match?(body, ~r/扫码验证|安全验证/)
  end
end
