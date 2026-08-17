defmodule EarssSourceWeread.CookieCloud do
  @moduledoc """
  Fetch Cookie header strings from a self-hosted
  [cookie_cloud_server](https://github.com/ll1zt/cookie_cloud_server) admin export.

  Example:

      curl -sS -H "Authorization: Bearer $PASSWORD" \\
        "http://127.0.0.1:4000/get/$UUID?format=header&domain=weread.qq.com"

  Results are cached in process ETS for a short TTL (see `EarssSourceWeread.Config`).
  """

  require Logger

  alias EarssSourceWeread.Config

  @table :earss_source_weread_cookie_cloud
  @default_domain "weread.qq.com"

  @doc """
  Return a Cookie header string from CookieCloud, or `nil` if not configured
  / fetch failed.

  Options:

    * `:force` — bypass cache (e.g. after WeRead `:auth_rejected`)
  """
  @spec fetch(keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch(opts \\ []) do
    with {:ok, conf} <- config() do
      force? = Keyword.get(opts, :force, false)

      if force? do
        do_fetch(conf)
      else
        case cache_get(conf.cache_key) do
          {:ok, cookie} -> {:ok, cookie}
          :miss -> do_fetch(conf)
        end
      end
    end
  end

  @doc "Drop cached cookie (all keys or one)."
  @spec invalidate() :: :ok
  def invalidate do
    ensure_table()

    case config() do
      {:ok, conf} ->
        :ets.delete(@table, conf.cache_key)
        :ok

      _ ->
        :ok
    end
  end

  @doc false
  def config do
    base = Config.cookie_cloud_base_url()
    uuid = Config.cookie_cloud_uuid()
    token = Config.cookie_cloud_token()

    cond do
      not present?(base) ->
        {:error, :cookie_cloud_not_configured}

      not present?(uuid) ->
        {:error, :cookie_cloud_missing_uuid}

      not present?(token) ->
        {:error, :cookie_cloud_missing_token}

      true ->
        domain = Config.cookie_cloud_domain() || @default_domain
        base = String.trim_trailing(base, "/")

        {:ok,
         %{
           base: base,
           uuid: uuid,
           token: token,
           domain: domain,
           cache_key: {base, uuid, domain},
           ttl_ms: Config.cookie_cloud_cache_ms()
         }}
    end
  end

  defp do_fetch(conf) do
    url =
      conf.base <>
        "/get/" <>
        URI.encode(conf.uuid) <>
        "?" <>
        URI.encode_query(%{"format" => "header", "domain" => conf.domain})

    headers = [
      {"authorization", "Bearer #{conf.token}"},
      {"accept", "text/plain, application/json, */*"}
    ]

    case Req.get(url,
           headers: headers,
           receive_timeout: Config.http_timeout_ms(),
           decode_body: false,
           redirect: true
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case normalize_body(body) do
          {:ok, cookie} ->
            cache_put(conf.cache_key, cookie, conf.ttl_ms)
            {:ok, cookie}

          {:error, _} = err ->
            err
        end

      {:ok, %Req.Response{status: 401}} ->
        {:error, :cookie_cloud_unauthorized}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :cookie_cloud_not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:cookie_cloud_http, status}}

      {:error, exception} ->
        Logger.warning("earss_source_weread CookieCloud fetch failed: #{inspect(exception)}")
        {:error, {:cookie_cloud_http, exception}}
    end
  end

  defp normalize_body(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        {:error, :cookie_cloud_empty}

      String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, %{"cookie" => c}} when is_binary(c) -> normalize_body(c)
          {:ok, %{"header" => c}} when is_binary(c) -> normalize_body(c)
          {:ok, %{"cookies" => c}} when is_binary(c) -> normalize_body(c)
          _ -> {:error, :cookie_cloud_invalid_body}
        end

      not String.contains?(trimmed, "=") ->
        {:error, :cookie_cloud_invalid_body}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_body(body) when is_list(body), do: normalize_body(IO.iodata_to_binary(body))
  defp normalize_body(_), do: {:error, :cookie_cloud_invalid_body}

  defp cache_get(key) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, cookie, expires_at}] when is_binary(cookie) and expires_at > now ->
        {:ok, cookie}

      [{^key, _, _}] ->
        :ets.delete(@table, key)
        :miss

      [] ->
        :miss
    end
  end

  defp cache_put(key, cookie, ttl_ms) do
    ensure_table()
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, cookie, expires_at})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp present?(s), do: is_binary(s) and String.trim(s) != ""
end
