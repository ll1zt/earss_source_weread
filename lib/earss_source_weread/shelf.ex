defmodule EarssSourceWeread.Shelf do
  @moduledoc """
  `GET /web/shelf/sync` — the WeRead bookshelf.

  公众号 (WeChat official accounts) subscribed in WeRead are listed on the
  shelf with `bookId` prefixed by `MP_WXS_`. This module filters them out.

  **Important:** `userVid` must be passed as an **empty string** — a non-empty
  value makes WeRead answer `-2012` (登录态失效). Verified against the
  we-mp-rss diagnostic matrix.
  """

  alias EarssSourceWeread.Client

  @type mp_entry :: %{book_id: String.t(), title: String.t() | nil}

  @doc """
  Fetch the shelf and return the subscribed 公众号 list.

  Returns `{:ok, [mp_entry]}` (empty list for an empty/no-MP shelf) or
  `{:error, term()}` (auth / rate-limit / network — never a spurious empty
  list, so a failed shelf is distinguishable from "no 公众号").
  """
  @spec fetch() :: {:ok, [mp_entry()]} | {:error, term()}
  def fetch do
    case Client.get_json("/web/shelf/sync", query: %{"userVid" => "", "synckey" => 0}) do
      {:ok, %{"books" => books}} when is_list(books) ->
        {:ok, books |> Enum.map(&mp_entry/1) |> Enum.reject(&is_nil/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp mp_entry(book) when is_map(book) do
    book_id = Map.get(book, "bookId")

    if is_binary(book_id) and String.starts_with?(book_id, "MP_WXS_") do
      %{book_id: book_id, title: Map.get(book, "title")}
    end
  end

  defp mp_entry(_), do: nil
end
