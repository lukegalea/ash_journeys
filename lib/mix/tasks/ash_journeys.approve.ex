defmodule Mix.Tasks.AshJourneys.Approve do
  @shortdoc "Publishes a passing run's figures and manifests, and updates the lock"
  @moduledoc """
  `mix ash_journeys.approve <run-id>`

  Publishes run `tmp/journeys/runs/<run-id>/` (`AshJourneys.Run`): each journey and
  locale's manifest and figures go to `priv/journeys/<locale>/<journey>/`, byte for
  byte, and `priv/journeys/journeys.lock.json` records their hashes.

  It refuses the whole run, writing nothing, when any part of it is not approvable
  (`AshJourneys.Approval`): a manifest that is missing or does not read, a failing
  or errored run, any retried step, any step not passed or not measured, a figure
  that was not settled or whose bytes do not match, a run of another declaration
  than the current one, or a run from a browser build other than the one the lock
  pins. The first approval into an empty lock pins the build the run used.

  A journey whose approved run already proves the same declaration, with every
  figure's raster the same within the lock's tolerance, is kept as it is.

  Review the changes first with `mix ash_journeys.impact <run-id>`.
  """

  use Mix.Task

  alias AshJourneys.Approval

  @impl true
  def run(args) do
    run_id =
      case OptionParser.parse(args, strict: []) do
        {[], [run_id], []} -> run_id
        _ -> Mix.raise("usage: mix ash_journeys.approve <run-id>")
      end

    declared = Mix.AshJourneys.declared!()

    case Approval.approve(File.cwd!(), run_id, declared) do
      {:ok, report} ->
        Mix.shell().info(format(report))

      {:error, problems} ->
        Mix.AshJourneys.refuse!("ash_journeys.approve: run #{run_id} is not approvable", problems)
    end
  end

  @doc false
  def format(report) do
    pinned =
      if report.pinned, do: ["pinned #{Approval.describe(report.pinned)} in the lock"], else: []

    lines =
      Enum.flat_map(report.results, fn result ->
        [
          "  #{result.outcome} #{result.journey} #{result.locale}"
          | Mix.AshJourneys.figure_lines(result.figures)
        ]
      end)

    Enum.join(["ash_journeys.approve: run #{report.run}" | pinned ++ lines], "\n")
  end
end
