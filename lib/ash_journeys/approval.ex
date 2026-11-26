defmodule AshJourneys.Approval do
  @moduledoc """
  Publishing a run: the checks `mix ash_journeys.approve` makes, and what it writes.

  `approve/3` publishes every journey and locale of one run, or none of them. A
  candidate is approvable only when all of these hold (`check/3`):

    * its manifest reads (`AshJourneys.Manifest.read/1`) and sits in the run,
      journey and locale directory it names;
    * it ran the current declaration: its declaration hash and version are those of
      the journey as declared now, in one of the journey's locales;
    * the run passed with no retries, and every declared step is recorded, in order,
      as the persona the declaration names, passed on its first attempt, with its
      cursor window;
    * a step that expects a trace recorded one: a correlation id and its span ids;
    * every declared figure, and nothing else, was captured on a settled page, with
      its raster measured, its highlight box when it declares a highlight, and a
      file whose bytes and pixels hash to what the manifest says;
    * it ran on the browser build the lock pins (`AshJourneys.Lock`);
    * the texts it recorded (`AshJourneys.Manifest`'s `texts`) are what the
      journey's text and labels resolve to now (`AshJourneys.L10n.texts/3`), so
      no page names a label its figures do not show.

  A candidate missing any of these is refused, with every reason. Nothing that was
  not measured counts as passing.

  ## What approval writes

  Each candidate's manifest and figures are copied byte for byte to
  `priv/journeys/<locale>/<journey>/`, replacing what was there, and its lock entry
  records their exact hashes. A candidate is **kept** instead, leaving the
  approved run in place, when that run already proves the same declaration on the
  same build and every figure's raster matches it within the lock's tolerance:
  re-shooting an unchanged journey then changes no committed file. A run that
  resolved any text differently is approved whole instead. Approval never
  mixes figures from two runs, and never records a hash its files do not have.
  """

  alias AshJourneys.{Json, L10n, Lock, Manifest, Raster, Run}
  alias AshJourneys.Manifest.{Figure, Step}

  @typedoc "How a figure compares with the approved run's."
  @type comparison ::
          :unchanged
          | :added
          | :removed
          | {:within_tolerance, Raster.diff()}
          | {:changed, Raster.diff() | String.t()}

  @typedoc "What approval did with one candidate."
  @type result :: %{
          journey: String.t(),
          locale: String.t(),
          outcome: :approved | :kept,
          figures: [{String.t(), comparison()}]
        }

  @doc """
  Approves run `run_id` under the project root `root` against the journeys
  `declared` (`AshJourneys.Lock.declared/1`). Writes nothing unless every candidate
  is approvable. `opts[:manifest_opts]` are the `AshA2ui.Manifest` options the
  surfaces render with, for resolving the journeys' labels (`check/4`).
  """
  @spec approve(Path.t(), String.t(), Lock.declared(), keyword()) ::
          {:ok, %{run: String.t(), pinned: Lock.build() | nil, results: [result()]}}
          | {:error, [String.t()]}
  def approve(root, run_id, declared, opts \\ []) do
    with {:ok, lock} <- Lock.read(root),
         {:ok, candidates} <- Run.load(root, run_id),
         :ok <- approvable(candidates, declared, lock, opts) do
      build = candidates |> hd() |> Map.fetch!(:manifest) |> build()
      results = Enum.map(candidates, &decide(root, &1, lock, build))
      journeys = Enum.reduce(results, lock.journeys, &record(root, &1, &2))
      Lock.write!(%{lock | browser: lock.browser || build, journeys: journeys}, root)

      {:ok,
       %{
         run: run_id,
         pinned: if(lock.browser, do: nil, else: build),
         results: Enum.map(results, &Map.drop(&1, [:candidate]))
       }}
    end
  end

  defp approvable(candidates, declared, lock, opts) do
    builds =
      for %{manifest: %Manifest{} = manifest} <- candidates, uniq: true, do: build(manifest)

    mixed =
      if length(builds) > 1,
        do: [
          "the run mixes browser builds (#{Enum.map_join(builds, ", ", &describe/1)}); figures come from one build"
        ],
        else: []

    case mixed ++ Enum.flat_map(candidates, &check(&1, declared, lock, opts)) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp decide(root, candidate, lock, build) do
    manifest = candidate.manifest
    figures = compare(root, candidate, lock)
    approved = get_in(lock.journeys, [manifest.journey, manifest.locale])

    kept? =
      approved != nil and approved.hash == manifest.declaration_hash and approved.browser == build and
        same_texts?(root, manifest) and
        Enum.all?(figures, fn {_key, comparison} -> unchanged?(comparison) end)

    %{
      journey: manifest.journey,
      locale: manifest.locale,
      outcome: if(kept?, do: :kept, else: :approved),
      figures: figures,
      candidate: candidate
    }
  end

  defp same_texts?(root, manifest) do
    dir = Lock.approved_dir(root, manifest.locale, manifest.journey)

    case Manifest.read(Path.join(dir, Manifest.file_name())) do
      {:ok, approved} -> approved.texts == manifest.texts
      {:error, _problems} -> false
    end
  end

  defp unchanged?(:unchanged), do: true
  defp unchanged?({:within_tolerance, _diff}), do: true
  defp unchanged?(_comparison), do: false

  defp record(_root, %{outcome: :kept}, journeys), do: journeys

  defp record(root, %{candidate: %{manifest: manifest, dir: dir}}, journeys) do
    target = Lock.approved_dir(root, manifest.locale, manifest.journey)
    File.rm_rf!(target)
    File.mkdir_p!(target)

    manifest_bytes = File.read!(Path.join(dir, Manifest.file_name()))
    File.write!(Path.join(target, Manifest.file_name()), manifest_bytes)

    figures =
      for %Step{figures: figures} = step <- manifest.steps,
          %Figure{} = figure <- figures,
          into: %{} do
        File.cp!(Path.join(dir, figure.file), Path.join(target, figure.file))

        {Manifest.figure_key(step, figure),
         Map.take(figure, [:file, :file_sha256, :raster_sha256, :width, :height])}
      end

    entry = %{
      run: manifest.run_id,
      commit: manifest.commit,
      version: manifest.version,
      hash: manifest.declaration_hash,
      environment: manifest.environment,
      browser: build(manifest),
      manifest_sha256: Json.sha256(manifest_bytes),
      figures: figures
    }

    Map.update(
      journeys,
      manifest.journey,
      %{manifest.locale => entry},
      &Map.put(&1, manifest.locale, entry)
    )
  end

  @doc "The browser build a manifest ran on: its name and version."
  @spec build(Manifest.t()) :: Lock.build()
  def build(%Manifest{browser: browser}), do: Map.take(browser, [:name, :version])

  @doc "A build as `name version`."
  @spec describe(Lock.build()) :: String.t()
  def describe(%{name: name, version: version}), do: "#{name} #{version}"

  @doc """
  Every reason candidate cannot be approved against `declared` and `lock`, each
  prefixed with its journey and locale. `[]` when it can.

  `opts[:manifest_opts]` are the `AshA2ui.Manifest` options the surfaces render
  with, for the text check. `texts: false` leaves the text check out, for a
  caller that makes it itself.
  """
  @spec check(Run.candidate(), Lock.declared(), Lock.t(), keyword()) :: [String.t()]
  def check(%{journey: journey, locale: locale} = candidate, declared, lock, opts \\ []) do
    problems =
      case candidate do
        %{problems: [_ | _] = problems} ->
          problems

        %{manifest: %Manifest{} = manifest} ->
          manifest_problems(manifest, candidate.dir, declared, lock, opts)
      end

    Enum.map(problems, &"#{journey}/#{locale}: #{&1}")
  end

  @doc """
  Every reason the run `manifest`, whose figures are in `dir`, cannot be approved
  against `declared` and `lock`, unprefixed. `check/4` is this for a candidate;
  `AshJourneys.Lock.verify/6` asks it of an approved run. Options are
  `check/4`'s.
  """
  @spec manifest_problems(Manifest.t(), Path.t(), Lock.declared(), Lock.t(), keyword()) ::
          [String.t()]
  def manifest_problems(manifest, dir, declared, lock, opts) do
    case declared[manifest.journey] do
      nil ->
        ["no configured module declares journey #{manifest.journey}"]

      %{ir: ir, hash: hash} = journey ->
        texts =
          if Keyword.get(opts, :texts, true) and manifest.locale in ir["locales"],
            do: texts_problems(manifest, journey, Keyword.get(opts, :manifest_opts, [])),
            else: []

        run_problems(manifest, ir, hash, lock) ++ steps_problems(manifest, ir, dir) ++ texts
    end
  end

  @doc """
  How the texts `manifest` recorded differ from what `journey`'s text resolves to
  now in its locale (`AshJourneys.L10n.texts/3`), one line per text. `[]` when
  they are the same.
  """
  @spec texts_problems(Manifest.t(), %{module: module(), ir: map()}, keyword()) :: [String.t()]
  def texts_problems(%Manifest{texts: recorded, locale: locale}, journey, manifest_opts) do
    case L10n.texts(journey, locale, manifest_opts) do
      {:ok, ^recorded} ->
        []

      {:ok, now} ->
        for key <- Enum.sort(Enum.uniq(Map.keys(recorded) ++ Map.keys(now))),
            recorded[key] != now[key] do
          "text #{key} was #{inspect(recorded[key])} in the run, and is now #{inspect(now[key])}; " <>
            "run it again"
        end

      {:error, problems} ->
        Enum.map(problems, &("text does not resolve: " <> &1))
    end
  end

  defp run_problems(manifest, ir, hash, lock) do
    [
      manifest.locale not in ir["locales"] &&
        "the journey is not declared in locale #{manifest.locale} (it declares #{Enum.join(ir["locales"], ", ")})",
      manifest.declaration_hash != hash &&
        "the run proves declaration #{short(manifest.declaration_hash)}, but the journey is now " <>
          "#{short(hash)}; run it again",
      manifest.version != ir["version"] &&
        "the run is of version #{manifest.version}, but the journey is at version #{ir["version"]}",
      manifest.status != :passed && "the run #{manifest.status}",
      manifest.retries > 0 &&
        "the run needed #{manifest.retries} retr#{if manifest.retries == 1, do: "y", else: "ies"}; " <>
          "only a pass on the first attempt is approvable",
      (lock.browser != nil and build(manifest) != lock.browser) &&
        "the run is from #{describe(build(manifest))}, but the lock pins #{describe(lock.browser)}"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp steps_problems(manifest, ir, dir) do
    declared = Enum.map(ir["steps"], & &1["name"])
    recorded = Enum.map(manifest.steps, & &1.name)
    steps = Map.new(ir["steps"], &{&1["name"], &1})

    sequence =
      cond do
        recorded == declared ->
          []

        Enum.sort(recorded) == Enum.sort(declared) ->
          [
            "the steps were recorded as #{Enum.join(recorded, ", ")}, not in the declared order #{Enum.join(declared, ", ")}"
          ]

        true ->
          Enum.map(declared -- recorded, &"step #{&1} was not recorded") ++
            Enum.map(recorded -- declared, &"step #{&1} is not declared")
      end

    sequence ++
      Enum.flat_map(manifest.steps, fn step ->
        if ir_step = steps[step.name], do: step_problems(step, ir_step, dir), else: []
      end)
  end

  defp step_problems(%Step{name: name} = step, ir_step, dir) do
    traced? =
      Enum.any?(
        ir_step["body"],
        &(&1["type"] == "expect" and (&1["trace"] != [] or &1["one_correlation"]))
      )

    problems =
      [
        step.actor != ir_step["as"] &&
          "ran as #{step.actor}, but the declaration says #{ir_step["as"]}",
        step.status != :passed && "#{step.status}#{if step.error, do: ": " <> step.error}",
        step.attempts != 1 &&
          "took #{step.attempts} attempts; only a pass on the first attempt is approvable",
        step.cursor == nil && "recorded no cursor window, so its assertions were not measured",
        (traced? and (step.correlation_id == nil or step.span_ids == [])) &&
          "expects a trace but recorded no correlation id and span ids, so it was not measured"
      ]
      |> Enum.filter(&is_binary/1)

    Enum.map(problems ++ figures_problems(step, ir_step, dir), &"step #{name} #{&1}")
  end

  defp figures_problems(step, ir_step, dir) do
    declared =
      for %{"type" => "figure"} = figure <- ir_step["body"],
          into: %{},
          do: {figure["name"], figure}

    recorded = Enum.map(step.figures, & &1.name)

    Enum.map(Map.keys(declared) -- recorded, &"did not capture figure #{&1}") ++
      Enum.map(recorded -- Enum.uniq(recorded), &"captured figure #{&1} twice") ++
      Enum.flat_map(step.figures, fn figure ->
        case declared[figure.name] do
          nil ->
            ["captured figure #{figure.name}, which it does not declare"]

          ir_figure ->
            Enum.map(figure_problems(figure, ir_figure, dir), &"figure #{figure.name} #{&1}")
        end
      end)
  end

  defp figure_problems(%Figure{} = figure, ir_figure, dir) do
    measured =
      [
        not figure.settled && "was captured before the page settled",
        unmeasured?(figure) && "has no raster hash, so it was not measured",
        (ir_figure["highlight"] != nil and figure.highlight == nil) &&
          "declares a highlight but recorded no highlight box",
        (ir_figure["highlight"] == nil and figure.highlight != nil) &&
          "recorded a highlight box but declares no highlight"
      ]
      |> Enum.filter(&is_binary/1)

    measured ++ file_problems(figure, dir)
  end

  defp unmeasured?(figure),
    do: Enum.any?([figure.raster_sha256, figure.width, figure.height], &is_nil/1)

  defp file_problems(figure, dir) do
    with {:ok, bytes} <- read_figure(dir, figure),
         :ok <- same(Json.sha256(bytes), figure.file_sha256, "its file's sha256"),
         {:ok, raster} <- decode(bytes) do
      if unmeasured?(figure),
        do: [],
        else:
          Enum.reject(
            [dimensions_problem(raster, figure), raster_problem(raster, figure)],
            &is_nil/1
          )
    else
      {:error, problem} -> [problem]
    end
  end

  defp read_figure(dir, figure) do
    case File.read(Path.join(dir, figure.file)) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error, "file #{figure.file} cannot be read (#{:file.format_error(reason)})"}
    end
  end

  defp decode(bytes) do
    case Raster.decode(bytes) do
      {:ok, raster} -> {:ok, raster}
      {:error, reason} -> {:error, "file does not decode: #{reason}"}
    end
  end

  defp same(found, found, _what), do: :ok

  defp same(found, recorded, what),
    do: {:error, "has #{what} #{short(found)}, but the manifest says #{short(recorded)}"}

  defp dimensions_problem(%Raster{width: w, height: h}, %Figure{width: w, height: h}), do: nil

  defp dimensions_problem(raster, figure),
    do:
      "is #{raster.width}x#{raster.height}, but the manifest says #{figure.width}x#{figure.height}"

  defp raster_problem(raster, figure) do
    case Raster.hash(raster) do
      hash when hash == figure.raster_sha256 ->
        nil

      hash ->
        "has raster hash #{short(hash)}, but the manifest says #{short(figure.raster_sha256)}"
    end
  end

  @doc """
  How each figure of `candidate` compares with the approved run of its journey and
  locale under `root`: by raster hash first, then, for a differing raster, pixel by
  pixel against the lock's tolerance. A figure the approved run lacks is `:added`;
  one only the approved run has is `:removed`.
  """
  @spec compare(Path.t(), Run.candidate(), Lock.t()) :: [{String.t(), comparison()}]
  def compare(root, %{manifest: %Manifest{} = manifest, dir: dir}, lock) do
    approved = get_in(lock.journeys, [manifest.journey, manifest.locale]) || %{figures: %{}}
    approved_dir = Lock.approved_dir(root, manifest.locale, manifest.journey)

    recorded =
      for %Step{figures: figures} = step <- manifest.steps, %Figure{} = figure <- figures do
        key = Manifest.figure_key(step, figure)
        {key, comparison(approved.figures[key], figure, approved_dir, dir, lock.tolerance)}
      end

    removed =
      for key <- Map.keys(approved.figures) -- Enum.map(recorded, &elem(&1, 0)),
          do: {key, :removed}

    Enum.sort(recorded ++ removed)
  end

  defp comparison(nil, _figure, _approved_dir, _dir, _tolerance), do: :added

  defp comparison(%{raster_sha256: same}, %Figure{raster_sha256: same}, _, _, _)
       when is_binary(same), do: :unchanged

  defp comparison(approved, figure, approved_dir, dir, tolerance) do
    with {:ok, before} <- raster(approved_dir, approved.file, "the approved figure"),
         {:ok, after_} <- raster(dir, figure.file, "the candidate figure") do
      diff = Raster.diff(before, after_)
      if Raster.within?(diff, tolerance), do: {:within_tolerance, diff}, else: {:changed, diff}
    else
      {:error, reason} -> {:changed, reason}
    end
  end

  @doc "The decoded raster of `file` in `dir`, with `what` naming it in an error."
  @spec raster(Path.t(), String.t(), String.t()) :: {:ok, Raster.t()} | {:error, String.t()}
  def raster(dir, file, what) do
    with {:ok, bytes} <- File.read(Path.join(dir, file)),
         {:ok, raster} <- Raster.decode(bytes) do
      {:ok, raster}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{what} #{file} cannot be read (#{:file.format_error(reason)})"}

      {:error, reason} ->
        {:error, "#{what} #{file} does not decode: #{reason}"}
    end
  end

  defp short(hash) when is_binary(hash), do: binary_part(hash, 0, min(12, byte_size(hash)))
  defp short(other), do: inspect(other)
end
