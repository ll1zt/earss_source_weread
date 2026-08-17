defmodule EarssSourceWeread.Adapter do
  @moduledoc """
  Earss source adapter for WeRead (微信读书) **subscribed 公众号 (MP)** articles.

  ## Routes

    * `earss://weread/shelf` — 书架合流: recent articles of every 公众号
      subscribed on the bookshelf, merged into one feed (`author` =
      公众号名). Follows shelf membership dynamically.
    * `earss://weread/mp/:bookId` — a single 公众号's articles.
      `bookId` accepts `MP_WXS_<digits>` or bare digits (auto-prefixed).

  Auth: static `EARSS_WEREAD_COOKIES` **or** CookieCloud
  (`EARSS_WEREAD_COOKIE_CLOUD_*`, domain `weread.qq.com`). At least `wr_vid`
  is required. See package README.

  ## Fetching (2026-08 status)

  WeRead **restored** `/web/mp/articles` — the we-mp-rss project reported
  `-2041` (deprecated) for it, but live probing on 2026-08-17 with a logged-in
  cookie returns the recent article list (latest first) **with real
  pagination** (`offset`, ~20/page) — 80+ contiguous items pulled across
  offset 0/20/40/60. The adapter does **list incremental polling**:

    1. fetch the article list per 公众号 (first poll = backfill
       `EARSS_WEREAD_BACKFILL_PAGES` pages of history, ~20 items/page);
    2. compare against the persisted cursor (`feed.adapter_cursor.seen` =
       `%{bookId => latestReviewId}`) and emit entries only for newer items;
    3. pull full body from the **public** mp.weixin.qq.com URL (no WeRead
       cookie — safe against WeRead rate-limits; `EARSS_WEREAD_FETCH_CONTENT`
       defaults to on).

  `published_at` uses the article's real publish timestamp (`mpInfo.time`).
  """

  @behaviour Earss.Source.Adapter

  require Logger

  alias Earss.Source.Adapter
  alias Earss.Source.Politeness
  alias EarssSourceWeread.{Config, MP, Public, Shelf}

  @impl true
  def id, do: "weread"

  @impl true
  def adapter_api, do: Adapter.api_version()

  @impl true
  def routes do
    [
      %{
        path: "shelf",
        description: "书架订阅的全部公众号近期文章（合流，author 显示公众号名；首拉回补历史）",
        example: "earss://weread/shelf"
      },
      %{
        path: "mp/:bookId",
        description: "单个公众号近期文章（MP_WXS_<数字> 或纯数字，自动补前缀；首拉回补历史）",
        example: "earss://weread/mp/MP_WXS_3528995129",
        params: [%{name: "bookId", required: true, example: "MP_WXS_3528995129"}]
      }
    ]
  end

  # —— resolve ——

  @impl true
  def resolve(input) when is_binary(input) do
    case URI.parse(String.trim(input)) do
      %URI{scheme: "earss", host: "weread", path: path} ->
        resolve_path(path)

      _ ->
        {:error, :unknown_route}
    end
  end

  def resolve(_), do: {:error, :invalid_input}

  defp resolve_path(path) do
    cond do
      path in ["/shelf", "/shelf/"] ->
        ok_resolve(%{
          source_url: "earss://weread/shelf",
          title: Config.shelf_title(),
          meta: %{kind: "shelf"}
        })

      String.starts_with?(path, "/mp/") ->
        with {:ok, book_id} <- MP.normalize_book_id(String.replace_prefix(path, "/mp/", "")) do
          ok_resolve(%{
            source_url: "earss://weread/mp/#{book_id}",
            title: "微信读书公众号 #{book_id}",
            meta: %{kind: "mp", book_id: book_id}
          })
        end

      true ->
        {:error, :unknown_route}
    end
  end

  defp ok_resolve(base) do
    {:ok, Map.merge(base, Politeness.default_plugin_intervals())}
  end

  # —— fetch ——

  @impl true
  def fetch(feed, opts \\ []) do
    link = field(feed, :link) || ""

    case resolve(link) do
      {:ok, %{meta: %{kind: "shelf"}}} ->
        fetch_shelf(feed, opts)

      {:ok, %{meta: %{kind: "mp", book_id: book_id}}} ->
        fetch_mp(feed, book_id, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_shelf(feed, opts) do
    force? = Keyword.get(opts, :force, false)

    case Shelf.fetch() do
      {:ok, mps} ->
        mps = maybe_cap(mps)
        seen0 = cursor_seen(feed) |> Map.new()
        state = %{entries: [], seen: seen0, err: nil}
        state = Enum.reduce(mps, state, &poll_mp_list(&1, &2, force?))
        finalize(state)

      {:error, _} = err ->
        err
    end
  end

  defp fetch_mp(feed, book_id, opts) do
    force? = Keyword.get(opts, :force, false)
    title = field(feed, :title) || book_id
    mp = %{book_id: book_id, title: title}
    seen0 = cursor_seen(feed) |> Map.new()

    case poll_mp_list(mp, %{entries: [], seen: seen0, err: nil}, force?) do
      %{entries: [], err: error} when error != nil ->
        {:error, error}

      %{entries: [], err: nil, seen: _seen} ->
        {:ok, :not_modified}

      %{entries: entries, seen: seen, err: _} ->
        {:ok,
         %{
           feed: %{title: mp_title(mp, entries)},
           entries: Enum.reverse(entries),
           cursor: %{"seen" => seen},
           content_hash: Map.get(seen, book_id, "")
         }}
    end
  end

  # One 公众号 via the article list: emit entries for items newer than the
  # last-seen reviewId. First poll (nil seen) backfills `backfill_pages`
  # pages of history (server pages are ~20 items).
  defp poll_mp_list(mp, state, force?) do
    book_id = mp.book_id
    interval_ms = Config.request_interval_ms()

    if interval_ms > 0 and (map_size(state.seen) > 0 or state.entries != []) do
      Process.sleep(interval_ms)
    end

    seen_id = Map.get(state.seen, book_id)

    fetched =
      cond do
        force? or is_nil(seen_id) ->
          MP.backfill(book_id, Config.backfill_pages())

        true ->
          MP.articles(book_id)
      end

    case fetched do
      {:ok, %{items: items}} when items != [] ->
        latest = hd(items)["review_id"]

        new_items =
          case seen_id do
            nil -> items
            id -> Enum.take_while(items, fn item -> item["review_id"] != id end)
          end

        state = %{state | seen: Map.put(state.seen, book_id, latest)}
        entries = Enum.map(new_items, &build_entry(&1, mp))
        %{state | entries: state.entries ++ entries}

      {:ok, _} ->
        state

      {:error, error} ->
        if state.err == nil, do: %{state | err: error}, else: state
    end
  end

  defp build_entry(item, mp) do
    author = item["author"] || mp.title || mp.book_id
    title = item["title"] || fallback_title(author)

    entry = %{
      guid: item["review_id"],
      link: "https://mp.weixin.qq.com/s/" <> item["original_id"],
      title: title,
      author: author,
      summary: item["summary"],
      published_at: item["published_at"] || DateTime.utc_now() |> DateTime.truncate(:second)
    }

    if Config.fetch_content?() do
      maybe_content(entry, item)
    else
      entry
    end
  end

  defp maybe_content(entry, item) do
    interval = Config.public_content_interval_ms()
    if interval > 0, do: Process.sleep(interval)

    case Public.fetch(item["original_id"]) do
      {:ok, html} when is_binary(html) and html != "" ->
        Map.put(entry, :content, html)

      {:error, reason} ->
        Logger.warning(
          "weread public content failed for #{item["review_id"]}: #{inspect(reason)}"
        )

        entry
    end
  rescue
    e ->
      Logger.warning("weread public content crashed for #{item["review_id"]}: #{inspect(e)}")
      entry
  end

  # —— finalize ——

  defp finalize(%{entries: [], err: error}) when error != nil, do: {:error, error}
  defp finalize(%{entries: [], err: nil}), do: {:ok, :not_modified}

  defp finalize(%{entries: entries, seen: seen}) do
    {:ok,
     %{
       feed: %{title: Config.shelf_title()},
       entries: Enum.reverse(entries),
       cursor: %{"seen" => seen}
     }}
  end

  # —— helpers ——

  defp maybe_cap(mps) do
    case Config.shelf_max_mps() do
      0 -> mps
      n when n > 0 -> Enum.take(mps, n)
    end
  end

  defp cursor_seen(feed) do
    case field(feed, :adapter_cursor) do
      %{"seen" => seen} when is_map(seen) -> seen
      %{seen: seen} when is_map(seen) -> seen
      _ -> %{}
    end
  end

  defp mp_title(mp, entries) do
    case entries do
      [%{author: author} | _] when is_binary(author) and author != "" -> author
      _ -> mp.title || mp.book_id
    end
  end

  defp fallback_title(author) when is_binary(author) and author != "",
    do: "#{author} 的微信读书文章"

  defp fallback_title(_), do: "微信读书公众号文章"

  defp field(map, key) when is_map(map) or is_struct(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
