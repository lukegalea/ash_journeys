defmodule AshJourneys.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ash_journeys,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Declarative user journeys for Ash: one declaration, proven by runs, published as docs.",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs README.md usage-rules.md LICENSE)],
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:spark, "~> 2.7"},
      {:ash, "~> 3.37"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end
end
