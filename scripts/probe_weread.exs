# Smoke-probe the WeRead API with your real cookie (static or CookieCloud).
#
# Usage (CookieCloud):
#   EARSS_WEREAD_COOKIE_CLOUD_URL=http://127.0.0.1:4000 \
#   EARSS_WEREAD_COOKIE_CLOUD_UUID=<uuid> \
#   EARSS_WEREAD_COOKIE_CLOUD_TOKEN=<server-password> \
#   mix run scripts/probe_weread.exs
#
# Usage (static cookie):
#   EARSS_WEREAD_COOKIES='wr_vid=...; wr_skey=...; ...' mix run scripts/probe_weread.exs
#
# Optional: EARSS_WEREAD_PROBE_MAX_MPS to cap how many 公众号 are cover-checked.
#
# Prints: auth status, every 公众号 on the shelf (bookId + title), and the
# latest article (title + reviewId) per 公众号 — no writes, no persistence.

alias EarssSourceWeread.{Config, Shelf, MP}

defmodule Probe do
  def run do
    IO.puts("== cookie source: #{Config.cookie_source()}")
    IO.puts("== base url: #{Config.base_url()}")

    case Config.cookies() do
      nil ->
        IO.puts("!! no cookie configured (EARSS_WEREAD_COOKIES or CookieCloud env)")
        IO.puts("   -> aborting")
        exit({:shutdown, :no_cookie})

      cookie ->
        case Config.validate_cookie(cookie) do
          {:ok, _} ->
            IO.puts("== cookie keys: " <>
                      Enum.map_join(Enum.sort(Config.required_cookie_keys()), ", ",
                        &"#{&1}=#{if Config.extract_cookie(cookie, &1), do: "ok", else: "MISSING"}"
                      ))

          {:error, {:missing_cookie, key}} ->
            IO.puts("!! cookie missing required key: #{key} — aborting")
            exit({:shutdown, :bad_cookie})
        end
    end

    case Shelf.fetch() do
      {:ok, []} ->
        IO.puts("== shelf OK but no MP_WXS_* 公众号 found")

      {:ok, mps} ->
        IO.puts("== shelf OK, #{length(mps)} 公众号:")
        Enum.each(mps, &IO.puts("   - #{&1.book_id}  #{&1.title || "(no title)"}"))

        max = probe_max()
        mps = if max > 0, do: Enum.take(mps, max), else: mps

        IO.puts("\n== latest article per 公众号 (cover):")
        Enum.each(mps, fn mp ->
          case MP.cover(mp.book_id) do
            {:ok, cover} ->
              IO.puts(
                "   #{mp.book_id}: #{cover["title"] || "(no title)"}  reviewId=#{cover["reviewId"] || "MISSING"}"
              )

            {:error, reason} ->
              IO.puts("   #{mp.book_id}: ERROR #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        IO.puts("!! shelf fetch failed: #{inspect(reason)}")
    end
  end

  defp probe_max do
    case System.get_env("EARSS_WEREAD_PROBE_MAX_MPS") do
      nil -> 0
      "" -> 0
      s -> String.to_integer(s)
    end
  end
end

Probe.run()