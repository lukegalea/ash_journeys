defmodule AshJourneys.Run do
  @moduledoc """
  A run's candidates on disk.

  A run writes one directory per journey and locale, holding its manifest
  (`AshJourneys.Manifest`) and its figures:

      tmp/journeys/runs/<run-id>/<journey>/<locale>/manifest.json
      tmp/journeys/runs/<run-id>/<journey>/<locale>/<figure files>

  Nothing under `tmp/journeys/runs/` is ever published. `mix ash_journeys.approve`
  publishes a run that passes its checks, and `mix ash_journeys.impact` compares one
  with what is approved.
  """

  alias AshJourneys.Manifest

  @runs "tmp/journeys/runs"
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @typedoc "One journey in one locale of a run, and its manifest when it reads."
  @type candidate :: %{
          journey: String.t(),
          locale: String.t(),
          dir: Path.t(),
          manifest: Manifest.t() | nil,
          problems: [String.t()]
        }

  @doc "The directory a run writes to, under the project root `root`."
  @spec dir(Path.t(), String.t()) :: Path.t()
  def dir(root, run_id), do: Path.join([root, @runs, run_id])

  @doc """
  The directory one journey and locale of a run writes to. Raises
  `ArgumentError` for a run id, journey or locale that is not a plain name.
  """
  @spec candidate_dir(Path.t(), String.t(), String.t(), String.t()) :: Path.t()
  def candidate_dir(root, run_id, journey, locale) do
    for name <- [run_id, journey, locale],
        not name?(name),
        do: raise(ArgumentError, "#{inspect(name)} is not a plain name")

    Path.join([dir(root, run_id), journey, locale])
  end

  @doc "Whether `name` can name a run, journey or locale directory."
  @spec name?(term()) :: boolean()
  def name?(name), do: is_binary(name) and name =~ @id

  @doc """
  Every candidate of run `run_id`. Each carries its manifest, or the problems that
  kept it from reading: no manifest, a malformed one, or one whose run, journey or
  locale is not the directory it was found in. `{:error, problems}` when the run
  does not exist or holds no candidates.
  """
  @spec load(Path.t(), String.t()) :: {:ok, [candidate()]} | {:error, [String.t()]}
  def load(root, run_id) do
    if name?(run_id),
      do: load_dir(dir(root, run_id)),
      else: {:error, ["#{inspect(run_id)} is not a run id"]}
  end

  @doc """
  `load/2` for a run directory given by its path; the run id is the directory's name.
  """
  @spec load_dir(Path.t()) :: {:ok, [candidate()]} | {:error, [String.t()]}
  def load_dir(dir) do
    dir = Path.expand(dir)
    run_id = Path.basename(dir)

    cond do
      not name?(run_id) -> {:error, ["#{inspect(run_id)} is not a run id"]}
      not File.dir?(dir) -> {:error, ["no run #{run_id} (#{dir} does not exist)"]}
      true -> dir |> candidates(run_id) |> found(run_id)
    end
  end

  defp found([], run_id), do: {:error, ["run #{run_id} holds no journeys"]}
  defp found(candidates, _run_id), do: {:ok, candidates}

  defp candidates(dir, run_id) do
    for journey <- subdirs(dir), locale <- locales(dir, journey) do
      candidate_dir = Path.join([dir, journey, locale])

      candidate = %{
        journey: journey,
        locale: locale,
        dir: candidate_dir,
        manifest: nil,
        problems: []
      }

      case Manifest.read(Path.join(candidate_dir, Manifest.file_name())) do
        {:ok, manifest} ->
          %{candidate | manifest: manifest, problems: misfiled(manifest, run_id, journey, locale)}

        {:error, problems} ->
          %{candidate | problems: problems}
      end
    end
  end

  # A journey directory with no locale under it is a candidate with no manifest,
  # not something to skip.
  defp locales(dir, journey) do
    case subdirs(Path.join(dir, journey)) do
      [] -> ["(none)"]
      locales -> locales
    end
  end

  defp subdirs(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(dir, &1)))
    |> Enum.sort()
  end

  defp misfiled(manifest, run_id, journey, locale) do
    for {field, found, expected} <- [
          {"run_id", manifest.run_id, run_id},
          {"journey", manifest.journey, journey},
          {"locale", manifest.locale, locale}
        ],
        found != expected,
        do: "manifest.#{field} is #{inspect(found)}, but it was found under #{inspect(expected)}"
  end
end
