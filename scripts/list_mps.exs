# List the 公众号 on your WeRead bookshelf with their bookIds (mps), and
# print copy-paste subscription URLs for the weread adapter.
#
# Usage (CookieCloud):
#   EARSS_WEREAD_COOKIE_CLOUD_URL=http://<cookie-cloud-host>:4000 \
#   EARSS_WEREAD_COOKIE_CLOUD_UUID=<uuid> \
#   EARSS_WEREAD_COOKIE_CLOUD_TOKEN=<server-password> \
#   mix run scripts/list_mps.exs
#
# Output:
#   MP_WXS_3905719449  DeepVan的逃生地牢
#   MP_WXS_3257158750  海边的西塞罗
#   ...
#   → 订阅全部: earss://weread/shelf
#   → 订阅指定: earss://weread/shelf?mps=MP_WXS_3905719449,MP_WXS_3257158750

alias EarssSourceWeread.{Config, Shelf}

defmodule ListMps do
  def run do
    case Config.cookies() do
      nil ->
        IO.puts("!! no cookie configured (EARSS_WEREAD_COOKIES or CookieCloud env)")
        exit({:shutdown, :no_cookie})

      _ ->
        :ok
    end

    case Shelf.fetch() do
      {:ok, []} ->
        IO.puts("书架 OK，但没有 MP_WXS_* 公众号")

      {:ok, mps} ->
        IO.puts("== 你书架上的公众号（mps）:")
        Enum.each(mps, &IO.puts("   #{&1.book_id}  #{&1.title || "(no title)"}"))

        ids = Enum.map_join(mps, ",", & &1.book_id)
        IO.puts("")
        IO.puts("→ 订阅全部: earss://weread/shelf")
        IO.puts("→ 订阅指定: earss://weread/shelf?mps=#{ids}")
        IO.puts("→ 单个订阅: earss://weread/mp/#{hd(mps).book_id}")

      {:error, reason} ->
        IO.puts("!! 书架获取失败: #{inspect(reason)}")
    end
  end
end

ListMps.run()