defmodule EarssSourceWeread.Extract do
  @moduledoc """
  Extract the article body out of the `/web/mp/content` HTML page.

  WeRead serves a full HTML document; the article markup lives in the
  `#js_content` node (fallback `.rich_media_content` — the classic WeChat page
  class). We remove `script`/`style` and promote lazy-loaded images
  (`data-src` → `src`) so readers show pictures.
  """

  alias Floki

  @doc """
  Return the article body as an HTML string, or `{:error, :content_not_found}`.
  """
  @spec js_content(String.t()) :: {:ok, String.t()} | {:error, term()}
  def js_content(html) when is_binary(html) and html != "" do
    doc = Floki.parse_document!(html)

    node =
      Floki.find(doc, "#js_content") |> List.first() ||
        Floki.find(doc, ".rich_media_content") |> List.first()

    case node do
      nil ->
        {:error, :content_not_found}

      tree ->
        {:ok,
         tree
         |> strip_noise()
         |> promote_images()
         |> unclamp()
         |> Floki.raw_html()
         |> String.trim()}
    end
  end

  def js_content(_), do: {:error, :content_not_found}

  # WeChat's original page hides the body container with inline
  # `visibility: hidden; opacity: 0` (revealed by JS). We serve static HTML,
  # so the article would be invisible in renderers (e.g. NetNewsWire's
  # WebKit). Drop those two declarations from the root node's style.
  defp unclamp({tag, attrs, children}) do
    attrs =
      attrs
      |> Enum.map(fn
        {"style", value} ->
          cleaned =
            value
            |> String.replace(~r/visibility\s*:\s*hidden;?\s*/i, "")
            |> String.replace(~r/opacity\s*:\s*0;?\s*/i, "")
            |> String.trim()

          {"style", cleaned}

        attr ->
          attr
      end)
      |> Enum.reject(fn
        {"style", ""} -> true
        _ -> false
      end)

    {tag, attrs, children}
  end

  defp unclamp(node), do: node

  defp strip_noise(html_tree) do
    html_tree
    |> Floki.traverse_and_update(fn
      {"script", _, _} -> nil
      {"style", _, _} -> nil
      {"link", _, _} -> nil
      node -> node
    end)
  end

  # WeChat lazy-loads images: <img data-src="..."> without src.
  # We also fold http:// image URLs to https:// — WeChat's image CDN
  # (mmbiz.qpic.cn) serves both, and http images are blocked as mixed
  # content on https pages / in many readers.
  defp promote_images(html_tree) do
    Floki.traverse_and_update(html_tree, fn
      {"img", attrs, children} = img ->
        # normalize every attribute value first (data-src, data-headimg, …),
        # then make sure a https src exists
        attrs = Enum.map(attrs, &normalize_attr/1)

        case find_attr(attrs, "data-src") do
          nil ->
            img

          src ->
            attrs =
              case find_attr(attrs, "src") do
                nil -> [{"src", src} | attrs]
                _ -> attrs
              end

            {"img", attrs, children}
        end

      {tag, attrs, children} when is_list(attrs) ->
        # normalize attribute values on every node (e.g. mpvoice albumurl/
        # data-headimg) so no http:// mixed content leaks remain
        {tag, Enum.map(attrs, &normalize_attr/1), children}

      node ->
        node
    end)
  end

  defp normalize_attr({key, value}) when is_binary(value), do: {key, normalize_img_url(value)}
  defp normalize_attr(attr), do: attr

  defp normalize_img_url(url) when is_binary(url) do
    if String.starts_with?(url, "http://") do
      "https://" <> String.trim_leading(url, "http://")
    else
      url
    end
  end

  defp find_attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end)
  end
end
