defmodule EarssSourceWeread.MixProject do
  use Mix.Project

  def project do
    [
      app: :earss_source_weread,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Earss source adapter for WeRead (微信读书) subscribed 公众号 (MP) articles"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EarssSourceWeread.Application, []}
    ]
  end

  defp deps do
    [
      # Contract package (C2). Host Earss overrides with packages/earss_source.
      {:earss_source, path: "../earss/packages/earss_source"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.36"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
