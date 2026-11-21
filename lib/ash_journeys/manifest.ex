defmodule AshJourneys.Manifest do
  @moduledoc """
  The run manifest: what one run of one journey in one locale recorded.

  A runner builds it and writes it with `write!/2` as `manifest.json` beside the
  run's figures, in `tmp/journeys/runs/<run-id>/<journey>/<locale>/`
  (`AshJourneys.Run`). `mix ash_journeys.approve` reads it back with `read/1` and
  publishes it unchanged, so the approved copy is the record of what was shot.

  The run:

    * `run_id`, `commit`: the run and the commit it ran.
    * `journey`, `version`, `declaration_hash`: the journey's id, its declared
      version and its IR hash (`AshJourneys.Ir.hash/1`) when it ran.
    * `locale`: the locale it ran in.
    * `environment`: `:test` (the seeded world), `:staging` or `:operated`. An
      `:operated` run records no figures: figures come only from a seeded world.
    * `browser`: `%{name:, version:, executable:}`. Figures are approved from one
      pinned build, named by `name` and `version`.
    * `framing`: the profile the browser contexts used (viewport, scale, motion,
      colour scheme, time zone), as JSON data with string keys.
    * `retries`: how many retries the run needed in all. Only `0` is a pass.
    * `status`: `:passed`, `:failed` or `:errored`.
    * `steps`: one `AshJourneys.Manifest.Step` per declared step, in order.

  ## Reading

  `read/1` and `from_json/1` check every field and return every problem with its
  path (`"manifest.steps[2].figures[0].file_sha256: missing"`). Unknown keys are
  problems too, so a runner that writes a field this format does not have is caught
  instead of ignored. A manifest that does not read is never approvable: a reader
  has no default to fall back on.
  """

  alias AshJourneys.Json
  alias AshJourneys.Manifest.{Figure, Step}

  @format 1
  @file_name "manifest.json"
  @environments [:test, :staging, :operated]
  @statuses [:passed, :failed, :errored]

  defstruct [
    :run_id,
    :commit,
    :journey,
    :version,
    :declaration_hash,
    :locale,
    :environment,
    :browser,
    :status,
    format: @format,
    framing: %{},
    retries: 0,
    steps: []
  ]

  @type environment :: :test | :staging | :operated
  @type status :: :passed | :failed | :errored
  @type browser :: %{name: String.t(), version: String.t(), executable: String.t()}

  @type t :: %__MODULE__{
          format: pos_integer(),
          run_id: String.t(),
          commit: String.t(),
          journey: String.t(),
          version: pos_integer(),
          declaration_hash: String.t(),
          locale: String.t(),
          environment: environment(),
          browser: browser(),
          framing: map(),
          retries: non_neg_integer(),
          status: status(),
          steps: [Step.t()]
        }

  @doc "The manifest format version, bumped on any change to its shape."
  @spec format() :: pos_integer()
  def format, do: @format

  @doc "The manifest's file name in its run directory."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc "The environment classes a manifest may record."
  @spec environments() :: [environment()]
  def environments, do: @environments

  @doc "The manifest as JSON data."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = manifest) do
    %{
      "format" => manifest.format,
      "run_id" => manifest.run_id,
      "commit" => manifest.commit,
      "journey" => manifest.journey,
      "version" => manifest.version,
      "declaration_hash" => manifest.declaration_hash,
      "locale" => manifest.locale,
      "environment" => string(manifest.environment),
      "browser" => stringify(manifest.browser),
      "framing" => stringify(manifest.framing),
      "retries" => manifest.retries,
      "status" => string(manifest.status),
      "steps" => Enum.map(manifest.steps, &step_json/1)
    }
  end

  defp step_json(%Step{} = step) do
    %{
      "name" => step.name,
      "actor" => step.actor,
      "label" => step.label,
      "status" => string(step.status),
      "attempts" => step.attempts,
      "cursor" => stringify(step.cursor),
      "correlation_id" => step.correlation_id,
      "span_ids" => step.span_ids,
      "figures" => Enum.map(step.figures, &figure_json/1),
      "error" => step.error
    }
  end

  defp figure_json(%Figure{} = figure) do
    %{
      "name" => figure.name,
      "file" => figure.file,
      "file_sha256" => figure.file_sha256,
      "raster_sha256" => figure.raster_sha256,
      "width" => figure.width,
      "height" => figure.height,
      "settled" => figure.settled,
      "highlight" => stringify(figure.highlight)
    }
  end

  defp string(nil), do: nil
  defp string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp stringify(nil), do: nil

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  @doc "The manifest's bytes as written: pretty JSON with sorted keys."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = manifest), do: manifest |> to_json() |> Json.encode!()

  @doc "Writes `manifest.json` into `dir`, creating it. Returns the file's path."
  @spec write!(t(), Path.t()) :: Path.t()
  def write!(%__MODULE__{} = manifest, dir) do
    path = Path.join(dir, @file_name)
    File.mkdir_p!(dir)
    File.write!(path, encode(manifest))
    path
  end

  @doc "Reads and checks a manifest file. A missing file is a problem like any other."
  @spec read(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def read(path) do
    case File.read(path) do
      {:ok, bytes} -> decode(bytes)
      {:error, :enoent} -> {:error, ["#{path}: no manifest"]}
      {:error, reason} -> {:error, ["#{path}: cannot be read (#{:file.format_error(reason)})"]}
    end
  end

  @doc "Decodes and checks manifest bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, [String.t()]}
  def decode(bytes) do
    with {:ok, map} <- Json.decode_object(bytes, "manifest"), do: from_json(map)
  end

  @known ~w(format run_id commit journey version declaration_hash locale environment browser
            framing retries status steps)

  @doc "Checks JSON data and builds the manifest it describes."
  @spec from_json(term()) :: {:ok, t()} | {:error, [String.t()]}
  def from_json(map) when is_map(map) do
    path = "manifest"

    case Json.field(map, "format", path, Json.check(&(&1 == @format), "#{@format}")) do
      {_, [_ | _] = problems} -> {:error, problems}
      {_format, []} -> fields(map, path)
    end
  end

  def from_json(_other), do: {:error, ["manifest: expected a JSON object"]}

  defp fields(map, path) do
    reads = [
      run_id: Json.field(map, "run_id", path, Json.string()),
      commit: Json.field(map, "commit", path, Json.string()),
      journey: Json.field(map, "journey", path, Json.string()),
      version: Json.field(map, "version", path, Json.integer(1)),
      declaration_hash: Json.field(map, "declaration_hash", path, Json.digest()),
      locale: Json.field(map, "locale", path, Json.string()),
      environment: Json.field(map, "environment", path, Json.enum(@environments)),
      browser: Json.field(map, "browser", path, Json.object(&browser/2)),
      framing:
        Json.field(map, "framing", path, Json.object(fn framing, _path -> {framing, []} end)),
      retries: Json.field(map, "retries", path, Json.integer(0)),
      status: Json.field(map, "status", path, Json.enum(@statuses)),
      steps: Json.field(map, "steps", path, Json.list(Json.object(&step/2)))
    ]

    problems =
      Json.unknown_keys(map, @known, path) ++ Enum.flat_map(reads, fn {_, {_, p}} -> p end)

    manifest = struct(__MODULE__, Enum.map(reads, fn {key, {value, _}} -> {key, value} end))
    problems = problems ++ figures_outside_a_seeded_world(manifest)

    if problems == [], do: {:ok, manifest}, else: {:error, problems}
  end

  defp figures_outside_a_seeded_world(%__MODULE__{environment: :operated, steps: steps})
       when is_list(steps) do
    if Enum.any?(steps, &match?(%Step{figures: [_ | _]}, &1)),
      do: ["manifest: an :operated run records no figures; figures come only from a seeded world"],
      else: []
  end

  defp figures_outside_a_seeded_world(_manifest), do: []

  defp browser(map, path) do
    record(map, path, %{}, ~w(name version executable),
      name: Json.string(),
      version: Json.string(),
      executable: Json.string()
    )
  end

  defp step(map, path) do
    record(
      map,
      path,
      %Step{},
      ~w(name actor label status attempts cursor correlation_id span_ids figures error),
      name: Json.string(),
      actor: Json.string(),
      label: Json.nullable(Json.string()),
      status: Json.enum(Step.statuses()),
      attempts: Json.integer(1),
      cursor: Json.nullable(Json.object(&cursor/2)),
      correlation_id: Json.nullable(Json.string()),
      span_ids: Json.list(Json.string()),
      figures: Json.list(Json.object(&figure/2)),
      error: Json.nullable(Json.string())
    )
  end

  defp cursor(map, path) do
    with {%{from: from, to: to} = cursor, []} <-
           record(map, path, %{}, ~w(from to), from: Json.integer(0), to: Json.integer(0)) do
      if from <= to,
        do: {cursor, []},
        else: {nil, ["#{path}: from (#{from}) is after to (#{to})"]}
    end
  end

  defp figure(map, path) do
    record(
      map,
      path,
      %Figure{},
      ~w(name file file_sha256 raster_sha256 width height settled highlight),
      name: Json.string(),
      file: Json.check(&file_name?/1, "a plain file name (no directory, not hidden)"),
      file_sha256: Json.digest(),
      raster_sha256: Json.nullable(Json.digest()),
      width: Json.nullable(Json.integer(1)),
      height: Json.nullable(Json.integer(1)),
      settled: Json.boolean(),
      highlight: Json.nullable(Json.object(&bbox/2))
    )
  end

  defp bbox(map, path) do
    record(map, path, %{}, ~w(x y width height),
      x: Json.check(&is_number/1, "a number"),
      y: Json.check(&is_number/1, "a number"),
      width: Json.check(&(is_number(&1) and &1 > 0), "a number > 0"),
      height: Json.check(&(is_number(&1) and &1 > 0), "a number > 0")
    )
  end

  # Reads each `key: reader` of `map` into `into`, a struct or a map.
  defp record(map, path, into, known, readers) do
    reads =
      Enum.map(readers, fn {key, read} ->
        {key, Json.field(map, Atom.to_string(key), path, read)}
      end)

    problems =
      Json.unknown_keys(map, known, path) ++ Enum.flat_map(reads, fn {_, {_, p}} -> p end)

    value = Enum.reduce(reads, into, fn {key, {value, _}}, acc -> Map.put(acc, key, value) end)
    {if(problems == [], do: value), problems}
  end

  defp file_name?(name),
    do:
      is_binary(name) and name != "" and Path.basename(name) == name and
        not String.starts_with?(name, ".")

  @doc "The figure's key in a lock: `\"<step>.<figure>\"`."
  @spec figure_key(Step.t() | String.t(), Figure.t() | String.t()) :: String.t()
  def figure_key(%Step{name: step}, figure), do: figure_key(step, figure)
  def figure_key(step, %Figure{name: figure}), do: figure_key(step, figure)
  def figure_key(step, figure) when is_binary(step) and is_binary(figure), do: "#{step}.#{figure}"
end
