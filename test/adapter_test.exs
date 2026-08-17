defmodule EarssSourceWeread.AdapterTest do
  use ExUnit.Case, async: false

  alias EarssSourceWeread.Adapter

  @mp1 "MP_WXS_100001"
  @mp2 "MP_WXS_100002"
  @t1 "token1abc"
  @t2 "token2xyz"
  @t3 "token3mno"
  @review1 "MP_WXS_100001_#{@t1}"
  @review2 "MP_WXS_100002_#{@t2}"

  setup do
    System.put_env("EARSS_WEREAD_COOKIES", "wr_vid=testvid; wr_skey=testkey")
    System.delete_env("EARSS_WEREAD_COOKIE_CLOUD_URL")
    System.delete_env("EARSS_WEREAD_COOKIE_CLOUD_UUID")
    System.delete_env("EARSS_WEREAD_COOKIE_CLOUD_TOKEN")
    System.put_env("EARSS_WEREAD_REQUEST_INTERVAL_MS", "0")
    System.put_env("EARSS_WEREAD_CONTENT_INTERVAL_MS", "0")
    System.put_env("EARSS_WEREAD_BACKFILL_PAGES", "1")
    System.put_env("EARSS_WEREAD_BASE_URL", "https://weread.qq.com")

    {:ok, bypass: Bypass.open()}
  end

  defp json_resp(conn, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(map))
  end

  # Build a /web/mp/articles response body (mirrors the real shape: each top
  # item has subReviews[0].review with reviewId + mpInfo).
  defp articles_body(book_id, items) do
    reviews =
      Enum.map(items, fn {token, title, summary, time} ->
        %{
          "createTime" => time,
          "subReviews" => [
            %{
              "review" => %{
                "reviewId" => "#{book_id}_#{token}",
                "mpInfo" => %{
                  "title" => title,
                  "content" => summary,
                  "mp_name" => "公众号#{book_id}",
                  "originalId" => token,
                  "time" => time,
                  "pic_url" => "https://pics/#{token}.jpg",
                  "readNum" => 10,
                  "likeNum" => 3
                }
              }
            }
          ]
        }
      end)

    %{"errCode" => 0, "reviews" => reviews, "synckey" => 99, "clearAll" => 1}
  end

  defp stub_shelf(bypass, books) do
    Bypass.expect(bypass, "GET", "/web/shelf/sync", fn conn ->
      json_resp(conn, %{"errCode" => 0, "books" => books})
    end)
  end

  defp stub_articles(bypass, book_id, items) do
    Bypass.expect(bypass, "GET", "/web/mp/articles", fn conn ->
      assert conn.query_string =~ "bookId=#{book_id}"

      # backfill probes offset=0,20,40… — only the first page carries items
      case URI.decode_query(conn.query_string) do
        %{"offset" => "0"} -> json_resp(conn, articles_body(book_id, items))
        _ -> json_resp(conn, %{"errCode" => 0, "reviews" => [], "synckey" => 99})
      end
    end)
  end

  describe "resolve/1" do
    test "shelf route", %{bypass: _} do
      assert {:ok, %{source_url: "earss://weread/shelf", meta: %{kind: "shelf"}}} =
               Adapter.resolve("earss://weread/shelf")
    end

    test "mp route keeps full bookId", %{bypass: _} do
      assert {:ok,
              %{
                source_url: "earss://weread/mp/MP_WXS_3528995129",
                meta: %{kind: "mp", book_id: "MP_WXS_3528995129"}
              }} = Adapter.resolve("earss://weread/mp/MP_WXS_3528995129")
    end

    test "mp route auto-prefixes bare digits", %{bypass: _} do
      assert {:ok, %{source_url: "earss://weread/mp/MP_WXS_3528995129"}} =
               Adapter.resolve("earss://weread/mp/3528995129")
    end

    test "unknown route rejected", %{bypass: _} do
      assert {:error, :unknown_route} = Adapter.resolve("earss://weread/nope")
      assert {:error, :unknown_route} = Adapter.resolve("https://example.com/feed.xml")
    end

    test "resolve carries plugin default intervals", %{bypass: _} do
      assert {:ok, %{min_refresh_interval: 30, default_refresh_interval: 60}} =
               Adapter.resolve("earss://weread/shelf")
    end
  end

  describe "fetch/2 — shelf (article list, no content)" do
    setup %{bypass: bypass} do
      System.put_env("EARSS_WEREAD_BASE_URL", "http://localhost:#{bypass.port}")
      System.put_env("EARSS_WEREAD_FETCH_CONTENT", "false")
      :ok
    end

    test "first poll backfills every 公众号's articles", %{bypass: bypass} do
      stub_shelf(bypass, [
        %{"bookId" => @mp1, "title" => "甲"},
        %{"bookId" => @mp2, "title" => "乙"},
        %{"bookId" => "normal-book", "title" => "普通书"}
      ])

      # single handler dispatching by bookId (avoids Bypass handler-queue order)
      Bypass.expect(bypass, "GET", "/web/mp/articles", fn conn ->
        case String.contains?(conn.query_string, @mp1) do
          true ->
            json_resp(
              conn,
              articles_body(@mp1, [
                {@t1, "甲第一篇", "摘要1", 1_786_925_450},
                {@t3, "甲旧文", "摘要3", 1_786_000_000}
              ])
            )

          false ->
            json_resp(conn, articles_body(@mp2, [{@t2, "乙第一篇", "摘要2", 1_786_800_000}]))
        end
      end)

      feed = %{link: "earss://weread/shelf", adapter_cursor: %{}}

      assert {:ok, payload} = Adapter.fetch(feed)
      assert %{feed: %{title: _}, entries: entries, cursor: %{"seen" => seen}} = payload
      assert length(entries) == 3

      e1 = Enum.find(entries, &(&1.guid == @review1))
      assert e1.title == "甲第一篇"
      assert e1.author == "公众号#{@mp1}"
      assert e1.summary == "摘要1"
      assert e1.link == "https://mp.weixin.qq.com/s/#{@t1}"
      assert e1.published_at == DateTime.from_unix!(1_786_925_450)
      refute Map.has_key?(e1, :content)

      assert seen == %{@mp1 => @review1, @mp2 => @review2}
    end

    test "already-seen latest reviewId returns :not_modified", %{bypass: bypass} do
      stub_shelf(bypass, [%{"bookId" => @mp1, "title" => "甲"}])
      stub_articles(bypass, @mp1, [{@t1, "甲第一篇", "摘要1", 1_786_925_450}])

      feed = %{link: "earss://weread/shelf", adapter_cursor: %{"seen" => %{@mp1 => @review1}}}

      assert {:ok, :not_modified} = Adapter.fetch(feed)
    end

    test "only newer-than-cursor items are emitted (mid-list backfill)", %{bypass: bypass} do
      stub_shelf(bypass, [%{"bookId" => @mp1, "title" => "甲"}])

      # cursor points at the OLD item; newest two are new
      stub_articles(bypass, @mp1, [
        {"newestA", "新文A", "摘要A", 1_790_000_000},
        {"newestB", "新文B", "摘要B", 1_787_000_000},
        {@t1, "已见过的甲第一篇", "摘要1", 1_786_925_450}
      ])

      feed = %{link: "earss://weread/shelf", adapter_cursor: %{"seen" => %{@mp1 => @review1}}}

      assert {:ok, %{entries: entries, cursor: %{"seen" => seen}}} = Adapter.fetch(feed)
      assert length(entries) == 2
      assert seen[@mp1] == "MP_WXS_100001_newestA"
    end

    test "one mp failing is skipped, others still emitted", %{bypass: bypass} do
      stub_shelf(bypass, [
        %{"bookId" => @mp1, "title" => "甲"},
        %{"bookId" => @mp2, "title" => "乙"}
      ])

      Bypass.expect(bypass, "GET", "/web/mp/articles", fn conn ->
        case String.contains?(conn.query_string, @mp1) do
          true -> json_resp(conn, %{"errCode" => -12000})
          false -> json_resp(conn, articles_body(@mp2, [{@t2, "乙第一篇", "摘要2", 1_786_800_000}]))
        end
      end)

      feed = %{link: "earss://weread/shelf", adapter_cursor: %{}}

      assert {:ok, %{entries: [e]}} = Adapter.fetch(feed)
      assert e.author == "公众号#{@mp2}"
    end

    test "auth failure propagates", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/web/shelf/sync", fn conn ->
        json_resp(conn, %{"errCode" => -2012})
      end)

      feed = %{link: "earss://weread/shelf", adapter_cursor: %{}}
      assert {:error, {:weread_auth, -2012}} = Adapter.fetch(feed)
    end
  end

  describe "fetch/2 — single mp with content" do
    setup %{bypass: bypass} do
      System.put_env("EARSS_WEREAD_BASE_URL", "http://localhost:#{bypass.port}")
      System.put_env("EARSS_WEREAD_PUBLIC_BASE_URL", "http://localhost:#{bypass.port}")
      System.put_env("EARSS_WEREAD_FETCH_CONTENT", "true")
      :ok
    end

    test "pulls full HTML body from the public URL for each new article", %{bypass: bypass} do
      stub_articles(bypass, @mp1, [
        {@t1, "甲第一篇", "摘要1", 1_786_925_450},
        {@t3, "甲旧文", "摘要3", 1_786_000_000}
      ])

      for token <- [@t1, @t3] do
        Bypass.expect(bypass, "GET", "/s/#{token}", fn conn ->
          html =
            "<html><body><div id=\"js_content\"><p>公开正文 #{token}</p></div></body></html>"

          conn
          |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
          |> Plug.Conn.resp(200, html)
        end)
      end

      feed = %{link: "earss://weread/mp/#{@mp1}", title: "公众号甲", adapter_cursor: %{}}

      assert {:ok, payload} = Adapter.fetch(feed)
      assert %{feed: %{title: "公众号#{@mp1}"}, entries: entries} = payload
      assert length(entries) == 2
      assert Enum.all?(entries, &(is_binary(&1.content) and &1.content =~ "公开正文"))
    end

    test "content failure degrades to summary-only entry", %{bypass: bypass} do
      stub_articles(bypass, @mp1, [{@t1, "甲第一篇", "有摘要", 1_786_925_450}])

      Bypass.expect(bypass, "GET", "/s/#{@t1}", fn conn ->
        Plug.Conn.resp(conn, 503, "slow down")
      end)

      feed = %{link: "earss://weread/mp/#{@mp1}", adapter_cursor: %{}}

      assert {:ok, %{entries: [e]}} = Adapter.fetch(feed)
      assert e.summary == "有摘要"
      refute Map.has_key?(e, :content)
    end

    test "no new article returns :not_modified", %{bypass: bypass} do
      stub_articles(bypass, @mp1, [{@t1, "甲第一篇", "摘要1", 1_786_925_450}])

      feed = %{
        link: "earss://weread/mp/#{@mp1}",
        adapter_cursor: %{"seen" => %{@mp1 => @review1}}
      }

      assert {:ok, :not_modified} = Adapter.fetch(feed)
    end
  end
end
