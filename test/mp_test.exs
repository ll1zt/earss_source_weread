defmodule EarssSourceWeread.MPTest do
  use ExUnit.Case, async: true

  alias EarssSourceWeread.MP

  describe "normalize_book_id/1" do
    test "accepts full MP_WXS_ form" do
      assert {:ok, "MP_WXS_3528995129"} = MP.normalize_book_id("MP_WXS_3528995129")
    end

    test "auto-prefixes bare digits" do
      assert {:ok, "MP_WXS_3528995129"} = MP.normalize_book_id("3528995129")
    end

    test "strips query and trailing slash" do
      assert {:ok, "MP_WXS_3528995129"} = MP.normalize_book_id("MP_WXS_3528995129?from=1")
      assert {:ok, "MP_WXS_3528995129"} = MP.normalize_book_id("3528995129/")
    end

    test "rejects garbage" do
      assert {:error, :invalid_book_id} = MP.normalize_book_id("foo")
      assert {:error, :invalid_book_id} = MP.normalize_book_id("MP_WXS_")
      assert {:error, :invalid_book_id} = MP.normalize_book_id("")
      assert {:error, :invalid_book_id} = MP.normalize_book_id(nil)
    end
  end

  describe "token_from_review/2 and link_from_review/2" do
    test "strips MP_WXS_<bookId>_ prefix with the bookId" do
      review = "MP_WXS_3528995129_4OcS7~rrtk2Lwe4P0YPiGg"

      assert MP.token_from_review(review, "MP_WXS_3528995129") == "4OcS7~rrtk2Lwe4P0YPiGg"

      assert MP.link_from_review(review, "MP_WXS_3528995129") ==
               "https://mp.weixin.qq.com/s/4OcS7~rrtk2Lwe4P0YPiGg"
    end

    test "falls back to the last _ segment without bookId" do
      review = "MP_WXS_3528995129_abcDEF123"

      assert MP.token_from_review(review) == "abcDEF123"
      assert MP.link_from_review(review) == "https://mp.weixin.qq.com/s/abcDEF123"
    end

    test "keeps a bare token verbatim" do
      assert MP.token_from_review("hello~world") == "hello~world"
      assert MP.token_from_review("plain") == "plain"
    end
  end

  describe "articles/1" do
    test "maps the real subReviews[].review + mpInfo shape" do
      body = %{
        "errCode" => 0,
        "reviews" => [
          %{
            "createTime" => 1_786_925_450,
            "subCount" => 1,
            "subReviews" => [
              %{
                "review" => %{
                  "reviewId" => "MP_WXS_3905719449_oMAfyP8lFz9eesaH~EYx9Q",
                  "mpInfo" => %{
                    "title" => "说好的最后一轮A股组合盘点",
                    "content" => "摘要文本",
                    "mp_name" => "DeepVan的逃生地牢",
                    "originalId" => "oMAfyP8lFz9eesaH~EYx9Q",
                    "time" => 1_786_925_450,
                    "pic_url" => "https://pics/x.jpg",
                    "readNum" => 12,
                    "likeNum" => 4
                  }
                }
              }
            ]
          }
        ],
        "synckey" => 123
      }

      bypass = Bypass.open()
      System.put_env("EARSS_WEREAD_BASE_URL", "http://localhost:#{bypass.port}")
      System.put_env("EARSS_WEREAD_COOKIES", "wr_vid=t")

      Bypass.expect(bypass, "GET", "/web/mp/articles", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, %{items: [item], synckey: 123}} =
               MP.articles("MP_WXS_3905719449")

      assert item["review_id"] == "MP_WXS_3905719449_oMAfyP8lFz9eesaH~EYx9Q"
      assert item["original_id"] == "oMAfyP8lFz9eesaH~EYx9Q"
      assert item["title"] == "说好的最后一轮A股组合盘点"
      assert item["author"] == "DeepVan的逃生地牢"
      assert item["summary"] == "摘要文本"
      assert item["published_at"] == DateTime.from_unix!(1_786_925_450)
    end

    test "rejects non-MP book ids" do
      assert {:error, :invalid_book_id} = MP.articles("123456")
    end

    test "backfill/3 walks pages in order and stops on empty" do
      bypass = Bypass.open()
      System.put_env("EARSS_WEREAD_BASE_URL", "http://localhost:#{bypass.port}")
      System.put_env("EARSS_WEREAD_COOKIES", "wr_vid=t")

      Bypass.expect(bypass, "GET", "/web/mp/articles", fn conn ->
        offset = URI.decode_query(conn.query_string)["offset"]
        # 3 pages of 1 item each, then empty
        body =
          case offset do
            "0" -> page("token-newest", 1_790_000_000)
            "20" -> page("token-mid", 1_789_000_000)
            "40" -> page("token-oldest", 1_788_000_000)
            _ -> %{"errCode" => 0, "reviews" => [], "synckey" => 0}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, %{items: items}} = MP.backfill("MP_WXS_3905719449", 3)

      assert Enum.map(items, & &1["review_id"]) == [
               "MP_WXS_3905719449_token-newest",
               "MP_WXS_3905719449_token-mid",
               "MP_WXS_3905719449_token-oldest"
             ]
    end

    defp page(token, time) do
      %{
        "errCode" => 0,
        "reviews" => [
          %{
            "createTime" => time,
            "subReviews" => [
              %{
                "review" => %{
                  "reviewId" => "MP_WXS_3905719449_#{token}",
                  "mpInfo" => %{
                    "title" => "文章#{token}",
                    "content" => "摘要",
                    "mp_name" => "某号",
                    "originalId" => token,
                    "time" => time
                  }
                }
              }
            ]
          }
        ],
        "synckey" => 0
      }
    end
  end
end
