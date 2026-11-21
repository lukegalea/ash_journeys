defmodule AshJourneys.Impact do
  @moduledoc """
  The reviewer's view of a run before it is approved (`mix ash_journeys.impact`).

  For each journey and locale of the run it reports whether `approve` would take it
  (`AshJourneys.Approval.check/3`, with every reason it would not), and how each
  figure compares with the approved run (`AshJourneys.Approval.compare/3`). Each
  changed figure is rendered beside its approved version, with the differing pixels
  marked (`AshJourneys.Raster.side_by_side/2`), under
  `tmp/journeys/impact/<run-id>/<journey>/<locale>/<step>.<figure>.png`.

  It writes nothing else and approves nothing.
  """

  alias AshJourneys.{Approval, Lock, Manifest, Raster, Run}

  @impact "tmp/journeys/impact"

  @type result :: %{
          journey: String.t(),
          locale: String.t(),
          problems: [String.t()],
          figures: [{String.t(), Approval.comparison()}],
          images: [Path.t()]
        }

  @doc "The directory a run's side-by-side images go to."
  @spec dir(Path.t(), String.t()) :: Path.t()
  def dir(root, run_id), do: Path.join([root, @impact, run_id])

  @doc "Compares run `run_id` under `root` with the approved runs."
  @spec report(Path.t(), String.t(), Lock.declared()) ::
          {:ok, %{run: String.t(), results: [result()]}} | {:error, [String.t()]}
  def report(root, run_id, declared) do
    with {:ok, lock} <- Lock.read(root),
         {:ok, candidates} <- Run.load(root, run_id) do
      File.rm_rf!(dir(root, run_id))

      {:ok,
       %{run: run_id, results: Enum.map(candidates, &result(root, run_id, &1, declared, lock))}}
    end
  end

  defp result(root, run_id, candidate, declared, lock) do
    figures = if candidate.manifest, do: Approval.compare(root, candidate, lock), else: []

    %{
      journey: candidate.journey,
      locale: candidate.locale,
      problems: Approval.check(candidate, declared, lock),
      figures: figures,
      images:
        Enum.flat_map(figures, fn
          {key, {:changed, %{}}} -> List.wrap(render(root, run_id, candidate, key, lock))
          _unchanged_or_unreadable -> []
        end)
    }
  end

  defp render(root, run_id, %{manifest: manifest, dir: dir} = candidate, key, lock) do
    approved = lock.journeys[manifest.journey][manifest.locale].figures[key]

    figure =
      Enum.find_value(manifest.steps, fn step ->
        Enum.find(step.figures, &(Manifest.figure_key(step, &1) == key))
      end)

    with {:ok, before} <-
           Approval.raster(
             Lock.approved_dir(root, manifest.locale, manifest.journey),
             approved.file,
             ""
           ),
         {:ok, after_} <- Approval.raster(dir, figure.file, "") do
      path = Path.join([dir(root, run_id), candidate.journey, candidate.locale, key <> ".png"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Raster.encode(Raster.side_by_side(before, after_)))
      path
    else
      {:error, _reason} -> nil
    end
  end
end
