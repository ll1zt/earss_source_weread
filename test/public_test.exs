defmodule EarssSourceWeread.PublicTest do
  use ExUnit.Case, async: false

  alias EarssSourceWeread.Public

  setup do
    bypass = Bypass.open()
    System.put_env("EARSS_WEREAD_PUBLIC_BASE_URL", "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass}
  end

  test "extracts js_content from the public article page", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/s/token1abc", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
      |> Plug.Conn.resp(200, "<html><body><div id=\"js_content\"><p>公开正文</p></div></body></html>")
    end)

    assert {:ok, html} = Public.fetch("token1abc")
    assert html =~ "公开正文"
  end

  test "detects captcha/risk pages", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/s/x", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
      |> Plug.Conn.resp(200, "<html><body><div>请完成安全验证</div></body></html>")
    end)

    assert {:error, :blocked} = Public.fetch("x")
  end

  test "http errors surface", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/s/y", fn conn ->
      Plug.Conn.resp(conn, 404, "nope")
    end)

    assert {:error, {:http, 404}} = Public.fetch("y")
  end

  test "missing content node is an error", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/s/z", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
      |> Plug.Conn.resp(200, "<html><body></body></html>")
    end)

    assert {:error, :content_not_found} = Public.fetch("z")
  end
end
