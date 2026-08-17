defmodule EarssSourceWeread.MP do
  @moduledoc """
  公众号 (MP) article access for WeRead.

  WeRead **deprecated the article-list endpoint** (`/web/mp/articles` answers
  `-2041`). The only remaining entry is `GET /api/mp/cover?bookId=` which
  returns **only the latest article** of the account:

      %{
        "name" => "公众号名",        # account display name
        "title" => "文章标题",
        "digest" => "摘要",
        "pic" => "封面",
        "reviewId" => "MP_WXS_<bookId>_<articleToken>"
      }

  Consequences:

    * no historical backfill is possible — a feed starts at the latest article;
    * incremental polling compares `reviewId` against the stored cursor and
      pulls the body only for unseen ids (see `EarssSourceWeread.Adapter`).
  """

  alias EarssSourceWeread.{Client, Extract}

  @doc """
  Article list page of a 公众号 (`offset` = items already loaded; page size
  is fixed at ~20 by the server, `count` is ignored).

  `GET /web/mp/articles` — **alive again as of 2026-08** (the we-mp-rss
  project reported `-2041` for it, but real-world probing with a logged-in
  cookie returns the recent article list, latest first, **with real pagination**
  via `offset` — probing on 2026-08-17 pulled 60+ contiguous items across
  offset 0/20/40). Each item carries: `reviewId`, `originalId` (WeChat
  article token), `title`, `mp_name`, `content` (digest), `time` (publish
  timestamp, unix seconds), `pic_url`, `readNum`, `likeNum`.

  Returns `%{items: [item], synckey: integer}` where each item is a map with
  string keys matching the raw sub-review fields above (plus `book_id`).

  Options: `:offset` — number of already-loaded items to skip (default 0).
  """
  @spec articles(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def articles(book_id, opts \\ []) when is_binary(book_id) do
    offset = Keyword.get(opts, :offset, 0)

    if String.starts_with?(book_id, "MP_WXS_") do
      case Client.get_json("/web/mp/articles",
             query: %{"bookId" => book_id, "offset" => Integer.to_string(offset)}
           ) do
        {:ok, data = %{"reviews" => reviews}} when is_list(reviews) ->
          items =
            reviews
            |> Enum.map(&review_item(&1, book_id))
            |> Enum.reject(&is_nil/1)

          {:ok, %{items: items, synckey: Map.get(data, "synckey"), book_id: book_id}}

        {:error, _} = err ->
          err
      end
    else
      {:error, :invalid_book_id}
    end
  end

  @doc """
  Fetch multiple pages for a full backfill (default page = 20 items).

  Stops early on an empty page or the first error; `max_pages` caps the
  request count. Used on first poll when the cursor has no seen id yet.
  """
  @spec backfill(String.t(), pos_integer(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def backfill(book_id, max_pages, page_size \\ 20) do
    do_backfill(book_id, max_pages, page_size, [], 0)
  end

  defp do_backfill(_book_id, max, _page_size, acc, offset) when offset >= max * 20 do
    {:ok, %{items: acc}}
  end

  defp do_backfill(book_id, max, page_size, acc, offset) do
    case articles(book_id, offset: offset) do
      {:ok, %{items: []}} ->
        {:ok, %{items: acc}}

      {:ok, %{items: items}} ->
        # pages arrive latest-first; append so the merged list stays latest-first
        do_backfill(book_id, max, page_size, acc ++ items, offset + max(page_size, length(items)))

      {:error, _} = err ->
        if acc == [], do: err, else: {:ok, %{items: acc}}
    end
  end

  # Parse one raw review block (top-level `{createTime, subReviews: [%{review: …}]}`)
  # into a flat item map. Returns nil when the block has no usable article.
  defp review_item(raw, book_id) do
    case raw["subReviews"] do
      [%{"review" => review} | _] ->
        case review["mpInfo"] do
          %{} = mp ->
            review_id = review["reviewId"]
            original = mp["originalId"]

            if is_binary(review_id) and review_id != "" and is_binary(original) and original != "" do
              %{
                "book_id" => book_id,
                "review_id" => review_id,
                "original_id" => original,
                "title" => str(mp["title"]),
                "author" => str(mp["mp_name"]),
                "summary" => str(mp["content"]),
                "pic_url" => str(mp["pic_url"]),
                "published_at" => unix_second(mp["time"]),
                "read_num" => num(mp["readNum"]),
                "like_num" => num(mp["likeNum"])
              }
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp str(nil), do: nil
  defp str(""), do: nil

  defp str(s) when is_binary(s) do
    s = String.trim(s)
    if s == "", do: nil, else: s
  end

  defp str(_), do: nil

  defp unix_second(n) when is_integer(n) and n > 0 do
    case DateTime.from_unix(n) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp unix_second(_), do: nil

  defp num(n) when is_integer(n), do: n
  defp num(_), do: 0

  @doc """
  Full article HTML body for a `reviewId`. Extracts `#js_content` markup.

  Returns `{:ok, html}` or `{:error, :content_not_found}` when the body of the
  page has no content node (or the endpoint answered an error).
  """
  @spec content(String.t()) :: {:ok, String.t()} | {:error, term()}
  def content(review_id) when is_binary(review_id) and review_id != "" do
    case Client.get_json("/web/mp/content",
           query: %{"reviewId" => review_id},
           accept: "text/html,application/xhtml+xml,*/*",
           decode_html: true
         ) do
      {:ok, body} when is_binary(body) ->
        case Extract.js_content(body) do
          {:ok, html} -> {:ok, html}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Derive the original mp.weixin.qq.com URL from a `reviewId`.

  `reviewId` looks like `MP_WXS_<bookId>_<articleToken>`; the trailing segment
  is the WeChat article short-token and may contain `~` — it must be preserved
  verbatim.
  """
  @spec link_from_review(String.t(), String.t()) :: String.t()
  def link_from_review(review_id, book_id \\ "") do
    token = token_from_review(review_id, book_id)
    "https://mp.weixin.qq.com/s/" <> token
  end

  @doc """
  Extract the trailing article token of a reviewId.

  Strips the `MP_WXS_<bookId>_` prefix when `book_id` matches the embedded one,
  otherwise falls back to everything after the last `_`.
  """
  @spec token_from_review(String.t(), String.t()) :: String.t()
  def token_from_review(review_id, book_id \\ "") do
    token = String.trim(review_id || "")

    cond do
      token == "" ->
        ""

      book_id != "" and String.starts_with?(token, book_id <> "_") ->
        String.replace_prefix(token, book_id <> "_", "")

      String.contains?(token, "_") ->
        token |> String.split("_") |> List.last() |> to_string()

      true ->
        token
    end
  end

  @doc """
  Validate/normalize a 公众号 bookId from user input.

  Accepts the full `MP_WXS_<digits>` form or bare digits (auto-prefixed), for
  a canonical `source_url`. Rejects anything else.
  """
  @spec normalize_book_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_book_id(input) when is_binary(input) do
    s =
      input
      |> String.trim()
      |> String.split("?")
      |> List.first()
      |> to_string()
      |> String.trim_trailing("/")
      |> String.trim()

    cond do
      s == "" ->
        {:error, :invalid_book_id}

      String.starts_with?(s, "MP_WXS_") ->
        rest = String.replace_prefix(s, "MP_WXS_", "")

        if valid_id?(rest), do: {:ok, s}, else: {:error, :invalid_book_id}

      String.match?(s, ~r/^\d+$/) ->
        {:ok, "MP_WXS_" <> s}

      true ->
        {:error, :invalid_book_id}
    end
  end

  def normalize_book_id(_), do: {:error, :invalid_book_id}

  defp valid_id?(rest), do: rest != "" and String.match?(rest, ~r/^\d+$/)
end
