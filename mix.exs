defmodule AshJourneys.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ash_journeys,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:spark, "~> 2.7"},
      {:ash, "~> 3.37"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:jcs, "~> 0.2"},
      {:ash_a2ui, github: "lukegalea/ash_a2ui", optional: true},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:jsv, "~> 0.26", only: :test, runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
