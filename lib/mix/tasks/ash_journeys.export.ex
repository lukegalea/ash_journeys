defmodule Mix.Tasks.AshJourneys.Export do
  @shortdoc "Writes each approved journey as a documentation page per locale"
  @moduledoc """
  `mix ash_journeys.export [--out DIR] [--figures DIR --figures-ref PATH]`

  Writes `<out>/<locale>/<journey>.md` for every journey declared by the modules in
  `config :ash_journeys, journeys: [...]`, in each locale it declares, with its
  figures as `<figures>/<digest>.png` (`AshJourneys.Export`). Pages are built only
  from `priv/journeys/`: the lock and the approved runs. A journey that is
  unapproved, stale or altered, or whose labels no longer resolve, stops the task
  with every reason, and nothing is written.

    * `--out`: where pages go. Defaults to `docs/journeys`.
    * `--figures`: where figures go. Defaults to `<out>/figures`. Pass
      `--figures-ref` with it: the path pages use to reach that directory, for
      example `/assets/journeys`. By default pages use `../figures`.
  """

  use Mix.Task

  alias AshJourneys.Export

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [out: :string, figures: :string, figures_ref: :string])

    if rest != [] or invalid != [] or (opts[:figures] != nil and opts[:figures_ref] == nil) do
      Mix.raise("usage: mix ash_journeys.export [--out DIR] [--figures DIR --figures-ref PATH]")
    end

    out = Keyword.get(opts, :out, "docs/journeys")
    figures = Keyword.get(opts, :figures, Path.join(out, "figures"))
    declared = Mix.AshJourneys.declared!()
    export_opts = if ref = opts[:figures_ref], do: [figures_ref: ref], else: []

    case Export.pages(File.cwd!(), declared, export_opts) do
      {:ok, export} ->
        Export.write!(export, out, figures)

        Mix.shell().info(
          "ash_journeys.export: #{length(export.pages)} page(s) in #{out}, " <>
            "#{length(export.figures)} figure(s) in #{figures}"
        )

      {:error, problems} ->
        Mix.AshJourneys.refuse!("ash_journeys.export: nothing was exported", problems)
    end
  end
end
