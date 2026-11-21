defmodule AshJourneys.Test.Runs do
  @moduledoc """
  Writes runs to disk the way a runner would: a passing, fully measured manifest for
  a declared journey, and a figure file for every figure it declares. Tests then
  break one thing at a time.
  """

  alias AshJourneys.{Json, Lock, Manifest, Raster, Run}
  alias AshJourneys.Manifest.{Figure, Step}

  @browser %{name: "chromium", version: "141.0.7390.37", executable: "/opt/chromium/chrome"}

  def browser, do: @browser

  @doc "A fresh project root under the test's tmp dir."
  def root(context) do
    root =
      Path.join(
        System.tmp_dir!(),
        "ash_journeys_#{context.test |> :erlang.phash2()}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  @doc "The declared journeys of the test fixtures."
  def declared do
    {:ok, declared} = Lock.declared([AshJourneys.Test.Offboarding])
    declared
  end

  @doc """
  A solid-colour raster with an optional set of `{x, y, rgba}` pixel overrides, so
  two figures can differ by an exact number of pixels.
  """
  def raster(width \\ 40, height \\ 30, overrides \\ [], colour \\ <<20, 40, 60, 255>>) do
    rgba =
      for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
        Enum.find_value(overrides, colour, fn {ox, oy, pixel} ->
          if {ox, oy} == {x, y}, do: pixel
        end)
      end

    %Raster{width: width, height: height, rgba: rgba}
  end

  @doc """
  The manifest a passing run of `journey` in `locale` records, for `rasters`
  (figure key => raster). Each figure's file is named after its key.
  """
  def manifest(declared, run_id, journey, locale, rasters) do
    %{ir: ir, hash: hash} = declared[journey]

    steps =
      ir["steps"]
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        traced? = Enum.any?(step["body"], &(&1["type"] == "expect" and &1["trace"] != []))

        figures =
          for %{"type" => "figure"} = figure <- step["body"] do
            key = Manifest.figure_key(step["name"], figure["name"])
            raster = Map.fetch!(rasters, key)

            %Figure{
              name: figure["name"],
              file: key <> ".png",
              file_sha256: Json.sha256(Raster.encode(raster)),
              raster_sha256: Raster.hash(raster),
              width: raster.width,
              height: raster.height,
              settled: true,
              highlight: if(figure["highlight"], do: %{x: 0, y: 4, width: 40, height: 8})
            }
          end

        %Step{
          name: step["name"],
          actor: step["as"],
          label: "#{index + 1}. #{step["name"]}",
          status: :passed,
          attempts: 1,
          cursor: %{from: index * 3, to: index * 3 + 3},
          correlation_id: if(traced?, do: "corr-#{index}"),
          span_ids: if(traced?, do: ["span-#{index}-a", "span-#{index}-b"], else: []),
          figures: figures
        }
      end)

    %Manifest{
      run_id: run_id,
      commit: "0123456789abcdef0123456789abcdef01234567",
      journey: journey,
      version: ir["version"],
      declaration_hash: hash,
      locale: locale,
      environment: :test,
      browser: @browser,
      framing: %{
        "viewport" => %{"width" => 1280, "height" => 800},
        "device_scale_factor" => 1,
        "reduced_motion" => "reduce"
      },
      retries: 0,
      status: :passed,
      steps: steps
    }
  end

  @doc "The figure keys `journey` declares."
  def figure_keys(declared, journey) do
    for step <- declared[journey].ir["steps"],
        %{"type" => "figure"} = figure <- step["body"],
        do: Manifest.figure_key(step["name"], figure["name"])
  end

  @doc "One raster per declared figure of `journey`, all alike."
  def rasters(declared, journey, raster \\ raster()),
    do: Map.new(figure_keys(declared, journey), &{&1, raster})

  @doc """
  Writes a candidate: the manifest (after `edit`) and one figure file per key of
  `rasters`. Returns the candidate directory.
  """
  def write!(root, declared, run_id, journey, locale, opts \\ []) do
    rasters = Keyword.get_lazy(opts, :rasters, fn -> rasters(declared, journey) end)
    edit = Keyword.get(opts, :edit, & &1)
    manifest = declared |> manifest(run_id, journey, locale, rasters) |> edit.()
    dir = Run.candidate_dir(root, run_id, journey, locale)
    Manifest.write!(manifest, dir)

    for {key, raster} <- rasters,
        do: File.write!(Path.join(dir, key <> ".png"), Raster.encode(raster))

    dir
  end

  @doc "Changes the step named `name` with `fun`."
  def step(manifest, name, fun) do
    %{manifest | steps: Enum.map(manifest.steps, &if(&1.name == name, do: fun.(&1), else: &1))}
  end

  @doc "Changes the figure named `figure` of step `name` with `fun`."
  def figure(manifest, name, figure, fun) do
    step(manifest, name, fn step ->
      %{step | figures: Enum.map(step.figures, &if(&1.name == figure, do: fun.(&1), else: &1))}
    end)
  end

  @doc """
  Every hash the lock records is the exact hash of the published file it names:
  the tolerance never reaches a recorded hash.
  """
  def assert_lock_is_exact!(root) do
    {:ok, lock} = Lock.read(root)

    for {journey, locales} <- lock.journeys, {locale, entry} <- locales do
      dir = Lock.approved_dir(root, locale, journey)
      manifest_bytes = File.read!(Path.join(dir, Manifest.file_name()))
      true = Json.sha256(manifest_bytes) == entry.manifest_sha256

      for {_key, figure} <- entry.figures do
        bytes = File.read!(Path.join(dir, figure.file))
        true = Json.sha256(bytes) == figure.file_sha256
        {:ok, raster} = Raster.decode(bytes)
        true = Raster.hash(raster) == figure.raster_sha256
      end
    end

    lock
  end
end
