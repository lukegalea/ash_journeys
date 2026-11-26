defmodule AshJourneys.Lock do
  @moduledoc """
  The lock: which run proves each journey in each locale.

  `priv/journeys/journeys.lock.json` is written by `mix ash_journeys.approve` and
  committed with the approved runs it names, which live in
  `priv/journeys/<locale>/<journey>/` (the run's manifest and figures, byte for
  byte as shot). Its shape:

      {
        "format": 1,
        "browser": {"name": "chromium", "version": "141.0.7390.37"},
        "tolerance": {"pixels": 32, "channel_delta": 64},
        "journeys": {
          "revoke_a_leavers_access": {
            "en": {
              "run": "…", "commit": "…", "version": 1, "hash": "<IR hash>",
              "environment": "test",
              "browser": {"name": "chromium", "version": "141.0.7390.37"},
              "manifest_sha256": "…",
              "figures": {
                "find_the_person.people": {
                  "file": "…png", "file_sha256": "…", "raster_sha256": "…",
                  "width": 1280, "height": 800
                }
              }
            }
          }
        }
      }

    * `browser` is the pinned build: figures are approved only from runs on it.
      The first approval into an empty lock pins the build it ran on. Moving the
      pin is an edit to this file, reviewed like any other, after which every
      journey needs a run on the new build to be approved again.
    * `tolerance` bounds the raster difference `approve` and `impact` treat as no
      change (`AshJourneys.Raster.within?/2`): the corner anti-aliasing wobble a
      long-lived page can show. It decides only whether a figure changed for
      review. Every hash the lock records is exact.

  `check/4` is the static gate, and `verify/6` the check behind it and behind every
  projection: a journey's approved run proves it only while the run's manifest
  proves the current declaration on the pinned build, its files are the ones the
  lock hashed, and its text still resolves as the run recorded it.
  """

  alias AshJourneys.{Info, Ir, Json}

  @format 1
  @file_name "journeys.lock.json"
  @priv "priv/journeys"
  @tolerance %{pixels: 32, channel_delta: 64}

  defstruct format: @format, browser: nil, tolerance: @tolerance, journeys: %{}

  @type build :: %{name: String.t(), version: String.t()}

  @type figure :: %{
          file: String.t(),
          file_sha256: String.t(),
          raster_sha256: String.t(),
          width: pos_integer(),
          height: pos_integer()
        }

  @type entry :: %{
          run: String.t(),
          commit: String.t(),
          version: pos_integer(),
          hash: String.t(),
          environment: AshJourneys.Manifest.environment(),
          browser: build(),
          manifest_sha256: String.t(),
          figures: %{String.t() => figure()}
        }

  @type t :: %__MODULE__{
          format: pos_integer(),
          browser: build() | nil,
          tolerance: AshJourneys.Raster.tolerance(),
          journeys: %{String.t() => %{String.t() => entry()}}
        }

  @typedoc "A declared journey, by id: where it is declared, its IR and its hash."
  @type declared :: %{String.t() => %{module: module(), ir: Ir.t(), hash: String.t()}}

  @doc "The tolerance an empty lock starts with."
  @spec default_tolerance() :: AshJourneys.Raster.tolerance()
  def default_tolerance, do: @tolerance

  @doc "The lock file's path under the project root `root`."
  @spec path(Path.t()) :: Path.t()
  def path(root), do: Path.join([root, @priv, @file_name])

  @doc "The directory holding the approved run of `journey` in `locale`."
  @spec approved_dir(Path.t(), String.t(), String.t()) :: Path.t()
  def approved_dir(root, locale, journey), do: Path.join([root, @priv, locale, journey])

  @doc """
  The journeys `modules` declare (each a module using `AshJourneys.Journeys`), by
  id. Two declarations of one id are a problem: the lock could not tell them apart.
  """
  @spec declared([module()]) :: {:ok, declared()} | {:error, [String.t()]}
  def declared(modules) do
    {journeys, problems} =
      Enum.flat_map_reduce(modules, [], fn module, problems ->
        if journeys_module?(module) do
          {Enum.map(Info.journeys(module), &{module, &1}), problems}
        else
          {[], problems ++ ["#{inspect(module)} does not use AshJourneys.Journeys"]}
        end
      end)

    duplicates =
      journeys
      |> Enum.group_by(fn {_module, journey} -> Atom.to_string(journey.name) end, &elem(&1, 0))
      |> Enum.filter(fn {_id, modules} -> length(modules) > 1 end)
      |> Enum.map(fn {id, modules} ->
        "journey #{id} is declared by #{Enum.map_join(modules, " and ", &inspect/1)}"
      end)

    case problems ++ duplicates do
      [] ->
        {:ok,
         Map.new(journeys, fn {module, journey} ->
           ir = Ir.build(journey)
           {ir["id"], %{module: module, ir: ir, hash: Ir.hash(ir)}}
         end)}

      problems ->
        {:error, problems}
    end
  end

  defp journeys_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      AshJourneys.Dsl in Spark.extensions(module)
  end

  @typedoc """
  The gate's verdict per declared journey and locale (`check/4`). `stale`,
  `altered` and `drifted` fail the gate, each with its reasons; `unapproved` (no
  approved run yet) and `orphaned` (a lock entry no journey declares any more)
  are reported and pass.
  """
  @type status :: %{
          current: [{String.t(), String.t()}],
          stale: [{String.t(), String.t(), [String.t()]}],
          altered: [{String.t(), String.t(), [String.t()]}],
          drifted: [{String.t(), String.t(), [String.t()]}],
          unapproved: [{String.t(), String.t()}],
          orphaned: [{String.t(), String.t()}]
        }

  @typedoc "Why `verify/6` refused an approved run."
  @type refusal :: :unapproved | :stale | :altered | :drifted

  @doc """
  Compares the declared journeys with the approved runs the lock names, under the
  project root `root`, by `verify/6` for each journey and locale. `opts` are
  `verify/6`'s.
  """
  @spec check(Path.t(), t(), declared(), keyword()) :: status()
  def check(root, %__MODULE__{journeys: locked} = lock, declared, opts \\ []) do
    statuses =
      for {id, %{ir: ir} = journey} <- Enum.sort(declared), locale <- ir["locales"] do
        case verify(root, lock, id, journey, locale, opts) do
          {:ok, _entry, _manifest} -> {:current, {id, locale}}
          {:error, :unapproved, _reasons} -> {:unapproved, {id, locale}}
          {:error, refusal, reasons} -> {refusal, {id, locale, reasons}}
        end
      end

    orphaned =
      for {id, locales} <- Enum.sort(locked),
          {locale, _entry} <- Enum.sort(locales),
          not (Map.has_key?(declared, id) and locale in declared[id].ir["locales"]),
          do: {id, locale}

    Map.merge(
      %{current: [], stale: [], altered: [], drifted: [], unapproved: [], orphaned: orphaned},
      Enum.group_by(statuses, &elem(&1, 0), &elem(&1, 1))
    )
  end

  @doc """
  Whether the approved run the lock names for journey `id` (`journey`, its
  `declared/1` entry) in `locale` still proves it, under the project root `root`.
  This is the one gate every projection passes through: the lock check, the
  exported pages and a host's in-app guide.

  The approved run is the manifest in `approved_dir/3`, not the lock entry: the
  entry only says which file it is. A run is refused as

    * `:unapproved` when the lock names none;
    * `:stale` when the declaration's hash is not the one approved, or the run is
      from another browser build than the one the lock pins (after the pin moves,
      every journey needs a run on the new build);
    * `:altered` when an approved file is missing or is not the one the lock
      hashed, the entry disagrees with its manifest (run, commit, version,
      declaration, locale, environment, build or figures), or the manifest no
      longer passes approval's checks (`AshJourneys.Approval.manifest_problems/5`):
      a hand edit to the lock cannot make another run current;
    * `:drifted` when the journey's text no longer resolves to what the run
      recorded (`AshJourneys.Approval.texts_problems/3`), for example after a
      label or a translation changed. `texts: false` leaves this check out;
      `:manifest_opts` are the `AshA2ui.Manifest` options the surfaces render with.

  The reasons do not name the journey or locale.
  """
  @spec verify(Path.t(), t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, entry(), AshJourneys.Manifest.t()} | {:error, refusal(), [String.t()]}
  def verify(root, %__MODULE__{} = lock, id, %{hash: hash} = journey, locale, opts \\ []) do
    dir = approved_dir(root, locale, id)

    with {:ok, entry} <- entry(lock, id, locale),
         :ok <- current(entry, hash, lock),
         {:ok, manifest} <- approved_manifest(dir, entry),
         :ok <- consistent(entry, manifest, id, locale),
         :ok <- still_approvable(manifest, dir, id, journey, lock),
         :ok <- texts(manifest, journey, opts) do
      {:ok, entry, manifest}
    end
  end

  defp entry(lock, id, locale) do
    case get_in(lock.journeys, [id, locale]) do
      nil -> {:error, :unapproved, ["no run is approved; run it, then mix ash_journeys.approve"]}
      entry -> {:ok, entry}
    end
  end

  defp current(%{hash: approved}, hash, _lock) when approved != hash,
    do:
      {:error, :stale,
       ["stale; the approved run proves #{short(approved)}, the declaration is #{short(hash)}"]}

  defp current(%{browser: build}, _hash, %{browser: pinned}) when build != pinned,
    do:
      {:error, :stale,
       [
         "stale; the approved run is from #{describe(build)}, but the lock pins #{describe(pinned)}; " <>
           "run it on the pinned build and approve it again"
       ]}

  defp current(_entry, _hash, _lock), do: :ok

  defp approved_manifest(dir, entry) do
    files =
      [{AshJourneys.Manifest.file_name(), entry.manifest_sha256}] ++
        for {_key, figure} <- Enum.sort(entry.figures), do: {figure.file, figure.file_sha256}

    with [] <- Enum.flat_map(files, fn {file, digest} -> altered(dir, file, digest) end),
         {:ok, manifest} <-
           AshJourneys.Manifest.read(Path.join(dir, AshJourneys.Manifest.file_name())) do
      {:ok, manifest}
    else
      {:error, problems} -> {:error, :altered, problems}
      problems -> {:error, :altered, problems}
    end
  end

  defp altered(dir, file, digest) do
    case File.read(Path.join(dir, file)) do
      {:ok, bytes} ->
        if Json.sha256(bytes) == digest,
          do: [],
          else: ["#{file} is not the file the lock approved"]

      {:error, _} ->
        ["#{file} is missing from #{dir}"]
    end
  end

  defp consistent(entry, manifest, id, locale) do
    figures =
      for %{figures: figures} = step <- manifest.steps,
          figure <- figures,
          into: %{},
          do:
            {AshJourneys.Manifest.figure_key(step, figure),
             Map.take(figure, [:file, :file_sha256, :raster_sha256, :width, :height])}

    pairs = [
      {"journey", id, manifest.journey},
      {"locale", locale, manifest.locale},
      {"run", entry.run, manifest.run_id},
      {"commit", entry.commit, manifest.commit},
      {"version", entry.version, manifest.version},
      {"hash", entry.hash, manifest.declaration_hash},
      {"environment", entry.environment, manifest.environment},
      {"browser", entry.browser, Map.take(manifest.browser, [:name, :version])},
      {"figures", entry.figures, figures}
    ]

    case for {what, locked, recorded} <- pairs, locked != recorded, do: {what, locked, recorded} do
      [] ->
        :ok

      mismatches ->
        {:error, :altered,
         Enum.map(mismatches, fn {what, locked, recorded} ->
           "the lock records #{what} #{inspect(locked)}, but its approved manifest has #{inspect(recorded)}"
         end)}
    end
  end

  defp still_approvable(manifest, dir, id, journey, lock) do
    case AshJourneys.Approval.manifest_problems(manifest, dir, %{id => journey}, lock,
           texts: false
         ) do
      [] -> :ok
      problems -> {:error, :altered, Enum.map(problems, &("the approved run " <> &1))}
    end
  end

  defp texts(manifest, journey, opts) do
    if Keyword.get(opts, :texts, true) do
      case AshJourneys.Approval.texts_problems(
             manifest,
             journey,
             Keyword.get(opts, :manifest_opts, [])
           ) do
        [] -> :ok
        problems -> {:error, :drifted, problems}
      end
    else
      :ok
    end
  end

  defp describe(%{name: name, version: version}), do: "#{name} #{version}"
  defp describe(nil), do: "no build"

  defp short(hash), do: binary_part(hash, 0, min(12, byte_size(hash)))

  @doc "Reads the lock under `root`. A missing file is an empty lock."
  @spec read(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def read(root) do
    path = path(root)

    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, map} <- Json.decode_object(bytes, path), do: from_json(map, path)

      {:error, :enoent} ->
        {:ok, %__MODULE__{}}

      {:error, reason} ->
        {:error, ["#{path}: cannot be read (#{:file.format_error(reason)})"]}
    end
  end

  @doc "Writes the lock under `root`."
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{} = lock, root) do
    path = path(root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Json.encode!(to_json(lock)))
  end

  @doc "The lock as JSON data."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = lock) do
    %{
      "format" => lock.format,
      "browser" => build_json(lock.browser),
      "tolerance" => %{
        "pixels" => lock.tolerance.pixels,
        "channel_delta" => lock.tolerance.channel_delta
      },
      "journeys" =>
        Map.new(lock.journeys, fn {id, locales} ->
          {id, Map.new(locales, fn {locale, entry} -> {locale, entry_json(entry)} end)}
        end)
    }
  end

  defp build_json(nil), do: nil
  defp build_json(%{name: name, version: version}), do: %{"name" => name, "version" => version}

  defp entry_json(entry) do
    %{
      "run" => entry.run,
      "commit" => entry.commit,
      "version" => entry.version,
      "hash" => entry.hash,
      "environment" => Atom.to_string(entry.environment),
      "browser" => build_json(entry.browser),
      "manifest_sha256" => entry.manifest_sha256,
      "figures" =>
        Map.new(entry.figures, fn {key, figure} ->
          {key, Map.new(figure, fn {k, v} -> {Atom.to_string(k), v} end)}
        end)
    }
  end

  defp from_json(map, path) do
    with {@format, []} <-
           Json.field(map, "format", path, Json.check(&(&1 == @format), "#{@format}")) do
      reads = [
        browser: Json.field(map, "browser", path, Json.nullable(Json.object(&build/2))),
        tolerance: Json.field(map, "tolerance", path, Json.object(&tolerance/2)),
        journeys: Json.field(map, "journeys", path, Json.object(&journeys/2))
      ]

      problems =
        Json.unknown_keys(map, ~w(format browser tolerance journeys), path) ++
          Enum.flat_map(reads, fn {_, {_, problems}} -> problems end)

      if problems == [],
        do: {:ok, struct(__MODULE__, Enum.map(reads, fn {key, {value, _}} -> {key, value} end))},
        else: {:error, problems}
    else
      {_value, problems} -> {:error, problems}
    end
  end

  defp build(map, path), do: record(map, path, name: Json.string(), version: Json.string())

  defp tolerance(map, path) do
    record(map, path,
      pixels: Json.integer(0),
      channel_delta: Json.check(&(is_integer(&1) and &1 in 0..255), "an integer from 0 to 255")
    )
  end

  defp journeys(map, path) do
    entries(map, path, fn locales, path -> entries(locales, path, &entry/2) end)
  end

  defp entries(map, path, read) do
    {pairs, problems} =
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} ->
        {value, problems} = Json.object(read).(value, "#{path}.#{key}")
        {{key, value}, problems}
      end)
      |> Enum.unzip()

    {Map.new(pairs), Enum.concat(problems)}
  end

  defp entry(map, path) do
    record(map, path,
      run: Json.string(),
      commit: Json.string(),
      version: Json.integer(1),
      hash: Json.digest(),
      environment: Json.enum(AshJourneys.Manifest.environments()),
      browser: Json.object(&build/2),
      manifest_sha256: Json.digest(),
      figures: Json.object(&entries(&1, &2, fn figure, path -> figure(figure, path) end))
    )
  end

  defp figure(map, path) do
    record(map, path,
      file: Json.string(),
      file_sha256: Json.digest(),
      raster_sha256: Json.digest(),
      width: Json.integer(1),
      height: Json.integer(1)
    )
  end

  defp record(map, path, readers) do
    reads =
      Enum.map(readers, fn {key, read} ->
        {key, Json.field(map, Atom.to_string(key), path, read)}
      end)

    known = Enum.map(readers, fn {key, _} -> Atom.to_string(key) end)

    problems =
      Json.unknown_keys(map, known, path) ++ Enum.flat_map(reads, fn {_, {_, p}} -> p end)

    {if(problems == [], do: Map.new(reads, fn {key, {value, _}} -> {key, value} end)), problems}
  end
end
