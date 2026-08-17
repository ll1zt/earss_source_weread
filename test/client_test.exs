defmodule EarssSourceWeread.ClientTest do
  use ExUnit.Case, async: false

  alias EarssSourceWeread.Client

  setup do
    System.put_env("EARSS_WEREAD_COOKIES", "wr_vid=testvid; wr_skey=testkey; wr_gid=gid")
    System.delete_env("EARSS_WEREAD_COOKIE_CLOUD_URL")
    System.delete_env("EARSS_WEREAD_COOKIE_CLOUD_UUID")
    System.delete_env("EARSS_WEREAD_COOKIE_CLOUD_TOKEN")

    bypass = Bypass.open()
    System.put_env("EARSS_WEREAD_BASE_URL", "http://localhost:#{bypass.port}")

    {:ok, bypass: bypass}
  end

  defp json_resp(conn, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(map))
  end

  test "returns JSON on errCode 0", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/api/mp/cover", fn conn ->
      assert conn.query_string =~ "bookId=MP_WXS_1"
      json_resp(conn, %{"errCode" => 0, "reviewId" => "MP_WXS_1_abc"})
    end)

    assert {:ok, %{"reviewId" => "MP_WXS_1_abc"}} =
             Client.get_json("/api/mp/cover", query: %{"bookId" => "MP_WXS_1"})
  end

  test "-2012 surfaces as auth error", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/web/shelf/sync", fn conn ->
      json_resp(conn, %{"errCode" => -2012, "errmsg" => "登录态失效"})
    end)

    assert {:error, {:weread_auth, -2012}} =
             Client.get_json("/web/shelf/sync", query: %{"userVid" => "", "synckey" => 0})
  end

  test "other errCodes surface with the code", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/web/shelf/sync", fn conn ->
      json_resp(conn, %{"errCode" => -12000})
    end)

    assert {:error, {:weread, -12000}} = Client.get_json("/web/shelf/sync")
  end

  test "content endpoint returns raw HTML when decode_html: true", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/web/mp/content", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
      |> Plug.Conn.resp(200, "<html><body><div id='js_content'>hi</div></body></html>")
    end)

    assert {:ok, body} =
             Client.get_json("/web/mp/content", query: %{"reviewId" => "x"}, decode_html: true)

    assert body =~ "js_content"
  end

  test "missing wr_vid cookie is rejected", %{bypass: _bypass} do
    System.put_env("EARSS_WEREAD_COOKIES", "other=1")
    assert {:error, {:missing_cookie, "wr_vid"}} = Client.get_json("/api/mp/cover")
  end

  test "missing cookies entirely is an error", %{bypass: _bypass} do
    System.delete_env("EARSS_WEREAD_COOKIES")
    assert {:error, :missing_cookies} = Client.get_json("/api/mp/cover")
  end
end
