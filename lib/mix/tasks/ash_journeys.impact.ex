defmodule Mix.Tasks.AshJourneys.Impact do
  @shortdoc "Shows what approving a run would change, with changed figures side by side"
  @moduledoc """
  `mix ash_journeys.impact <run-id>`

  For each journey and locale of run `tmp/journeys/runs/<run-id>/`, prints whether
  `mix ash_journeys.approve` would take it, with every reason it would not, and how
  each figure compares with the approved one: unchanged (same raster hash), within
  the lock's tolerance, changed, added or removed. Each changed figure is written
  beside its approved version, with the differing pixels marked, to
  `tmp/journeys/impact/<run-id>/` (`AshJourneys.Impact`).

  Exits non-zero when any part of the run is not approvable. It approves nothing.
  """

  use Mix.Task

  alias AshJourneys.Impact

  @impl true
  def run(args) do
    run_id =
      case OptionParser.parse(args, strict: []) do
        {[], [run_id], []} -> run_id
        _ -> Mix.raise("usage: mix ash_journeys.impact <run-id>")
      end

    declared = Mix.AshJourneys.declared!()

    case Impact.report(File.cwd!(), run_id, declared) do
      {:ok, report} ->
        Mix.shell().info(format(report))

        if Enum.any?(report.results, &(&1.problems != [])),
          do: Mix.raise("ash_journeys.impact: run #{run_id} is not approvable")

      {:error, problems} ->
        Mix.AshJourneys.refuse!("ash_journeys.impact: run #{run_id} cannot be compared", problems)
    end
  end

  @doc false
  def format(report) do
    lines =
      Enum.flat_map(report.results, fn result ->
        verdict = if result.problems == [], do: "approvable", else: "not approvable"

        ["  #{result.journey} #{result.locale}: #{verdict}"] ++
          Enum.map(result.problems, &"    refused: #{&1}") ++
          Mix.AshJourneys.figure_lines(result.figures) ++
          Enum.map(result.images, &"    side by side: #{Path.relative_to_cwd(&1)}")
      end)

    Enum.join(["ash_journeys.impact: run #{report.run}" | lines], "\n")
  end
end
