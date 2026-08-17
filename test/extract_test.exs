defmodule EarssSourceWeread.ExtractTest do
  use ExUnit.Case, async: true

  alias EarssSourceWeread.Extract

  @html """
  <html><head><title>x</title></head>
  <body>
    <div id="js_content">
      <script>bad()</script>
      <style>.x{}</style>
      <p>正文段落</p>
      <img data-src="https://cdn.example/pic.jpg" alt="图">
    </div>
  </body></html>
  """

  test "extracts #js_content and strips script/style" do
    assert {:ok, html} = Extract.js_content(@html)
    refute html =~ "bad()"
    refute html =~ "<style"
    assert html =~ "正文段落"
  end

  test "promotes lazy-loaded img data-src to src" do
    assert {:ok, html} = Extract.js_content(@html)
    assert html =~ ~s(src="https://cdn.example/pic.jpg")
  end

  test "folds http image URLs to https (mixed-content guard)" do
    html =
      ~s(<html><body><div id="js_content">) <>
        ~s(<img data-src="http://mmbiz.qpic.cn/mmbiz_jpg/abc" src="http://mmbiz.qpic.cn/x">) <>
        ~s(<img src="https://mmbiz.qpic.cn/y">) <>
        ~s(</div></body></html>)

    assert {:ok, out} = Extract.js_content(html)
    assert out =~ ~s(src="https://mmbiz.qpic.cn/mmbiz_jpg/abc")
    assert out =~ ~s(src="https://mmbiz.qpic.cn/x")
    assert out =~ ~s(src="https://mmbiz.qpic.cn/y")
    refute out =~ "http://"
  end

  test "falls back to .rich_media_content" do
    html = ~s(<html><body><div class="rich_media_content"><p>老式页面</p></div></body></html>)
    assert {:ok, out} = Extract.js_content(html)
    assert out =~ "老式页面"
  end

  test "error when no content node" do
    assert {:error, :content_not_found} = Extract.js_content("<html><body></body></html>")
    assert {:error, :content_not_found} = Extract.js_content("")
  end
end
