defmodule AshJourneys.Messages do
  @moduledoc """
  A run as a [Cucumber Messages](https://github.com/cucumber/messages) stream, so
  report tooling that reads that protocol can read journey runs.

  This is a projection of the run manifests (`AshJourneys.Manifest`) of one run, never
  a source: nothing is read back from it, and it records nothing a manifest does not.
  `candidates/1` loads a run directory and `build/2` turns its candidates into the
  messages, one map per envelope; `encode/1` writes them as NDJSON.

  ## The stream

  `meta`, then `testRunStarted`, then for each journey and locale of the run (in that
  order): a `source` (the journey as plain Gherkin text, so a viewer has something to
  show), a `pickle` (one pickle step per journey step), a `testCase`, a
  `testCaseStarted`, a `testStepStarted` and `testStepFinished` per step with the
  step's figures as attachments between them, and a `testCaseFinished`; and last
  `testRunFinished`. There is no `gherkinDocument`: the pickle is built from the
  manifest, and its step text is the step's first narration as the run resolved it
  in its locale, or the step's name.

  ## Statuses, honestly

  A step is `PASSED` only when it passed on its first attempt and everything it
  recorded was measured. Anything less is never `PASSED`:

    * passed, but it took more than one attempt: `UNKNOWN`, the message says how many;
    * passed, but it recorded no cursor window, a figure captured before the page
      settled, a figure with no raster hash or size, or a figure file that is missing
      or differs from its recorded sha256: `UNKNOWN`, the message says which;
    * `errored` (it could not be run to a verdict): `UNKNOWN`;
    * `failed`: `FAILED`, with its error as the exception;
    * `skipped`: `SKIPPED`.

  `testRunFinished.success` is true only when every manifest passed with no retry
  and every one of its steps is `PASSED`. A manifest with no steps is not a pass.

  ## Time

  A manifest records no clock, so every timestamp is the epoch and every duration is
  zero. They are unmeasured, and the export is a pure function of the run directory.

  ## Figures

  Each figure of a step is an attachment of the step, by media type (from the file's
  extension) and sha256. By default it is an `externalAttachment` whose `url` is the
  figure's `file:` URL with the digest as its fragment (`#sha256=<hex>`); with
  `embed: true` it is an `attachment` carrying the bytes, base64, and the file's name.
  Only a figure whose file is there and matches its recorded sha256 is attached.

  ## Reading it back

  `summary/1` reads the step count, statuses and figure hashes back out of a stream.
  """

  alias AshJourneys.{Json, Manifest, Run}
  alias AshJourneys.Manifest.{Figure, Step}

  @protocol_version "35.0.0"
  @epoch %{"seconds" => 0, "nanos" => 0}
  @media_types %{".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg"}

  @typedoc "One envelope of the stream, as JSON data."
  @type message :: %{String.t() => map()}

  @doc "The version of the Cucumber Messages protocol the stream follows."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  Loads the run directory `dir` (`tmp/journeys/runs/<run-id>`). A directory that does
  not exist, holds no journeys, or holds a candidate whose manifest is missing,
  malformed or misfiled is `{:error, problems}`: nothing of it is exported.
  """
  @spec candidates(Path.t()) :: {:ok, [Run.candidate()]} | {:error, [String.t()]}
  def candidates(dir) do
    with {:ok, candidates} <- Run.load_dir(dir) do
      case Enum.flat_map(candidates, & &1.problems) do
        [] -> {:ok, candidates}
        problems -> {:error, problems}
      end
    end
  end

  @doc """
  The messages of `candidates` (as `candidates/1` returns them). Options: `embed:
  true` carries figures as base64 attachments instead of referencing their files.
  """
  @spec build([Run.candidate()], keyword()) :: [message()]
  def build([first | _] = candidates, opts \\ []) do
    embed? = Keyword.get(opts, :embed, false)
    cases = Enum.map(candidates, &test_case(&1, embed?))
    run_id = first.manifest.run_id

    [%{"meta" => meta(first.manifest)}, %{"testRunStarted" => run_started(run_id)}] ++
      Enum.flat_map(cases, & &1.messages) ++
      [%{"testRunFinished" => run_finished(run_id, cases)}]
  end

  @doc "The messages as NDJSON: one compact JSON object per line."
  @spec encode([message()]) :: String.t()
  def encode(messages), do: Enum.map_join(messages, &(Jason.encode!(&1) <> "\n"))

  defp meta(%Manifest{browser: browser}) do
    %{
      "protocolVersion" => @protocol_version,
      "implementation" => %{
        "name" => "ash_journeys",
        "version" => to_string(Application.spec(:ash_journeys, :vsn))
      },
      "runtime" => %{"name" => browser.name, "version" => browser.version},
      "os" => %{"name" => "unknown"},
      "cpu" => %{"name" => "unknown"}
    }
  end

  defp run_started(run_id), do: %{"id" => run_id, "timestamp" => @epoch}

  defp run_finished(run_id, cases) do
    problems =
      for %{id: id, problems: problems} <- cases, problem <- problems, do: "#{id}: #{problem}"

    base = %{"success" => problems == [], "timestamp" => @epoch, "testRunStartedId" => run_id}
    if problems == [], do: base, else: Map.put(base, "message", Enum.join(problems, "; "))
  end

  defp test_case(%{manifest: manifest, dir: dir}, embed?) do
    id = "#{manifest.journey}/#{manifest.locale}"
    steps = Enum.map(manifest.steps, &{&1, step_result(&1, dir)})

    problems =
      Enum.filter(
        [
          manifest.status != :passed && "the run #{manifest.status}",
          manifest.retries > 0 && "the run needed #{manifest.retries} retries",
          manifest.steps == [] && "the run recorded no steps"
        ] ++
          for(
            {step, {status, _, _, _}} <- steps,
            status != "PASSED",
            do: "step #{step.name} is #{status}"
          ),
        &is_binary/1
      )

    %{
      id: id,
      problems: problems,
      messages:
        [
          %{"source" => source(id, manifest)},
          %{"pickle" => pickle(id, manifest)},
          %{"testCase" => case_definition(id, manifest)},
          %{"testCaseStarted" => case_started(id)}
        ] ++
          Enum.flat_map(steps, &step_messages(id, &1, embed?)) ++
          [%{"testCaseFinished" => case_finished(id)}]
    }
  end

  defp source(id, manifest) do
    %{
      "uri" => uri(id),
      "mediaType" => "text/x.cucumber.gherkin+plain",
      "data" =>
        Enum.join(
          [
            "# language: #{manifest.locale}",
            "Feature: #{one_line(title(manifest))}",
            "",
            "  Scenario: #{one_line(manifest.texts["goal"] || title(manifest))}"
          ] ++ Enum.map(manifest.steps, &"    * #{one_line(step_text(manifest, &1))}"),
          "\n"
        ) <> "\n"
    }
  end

  defp pickle(id, manifest) do
    %{
      "id" => "pickle:" <> id,
      "uri" => uri(id),
      "name" => title(manifest),
      "language" => manifest.locale,
      "astNodeIds" => ["scenario:" <> id],
      "tags" => [],
      "steps" =>
        for step <- manifest.steps do
          %{
            "id" => pickle_step_id(id, step),
            "text" => step_text(manifest, step),
            "astNodeIds" => [test_step_id(id, step)]
          }
        end
    }
  end

  defp case_definition(id, manifest) do
    %{
      "id" => "case:" <> id,
      "pickleId" => "pickle:" <> id,
      "testRunStartedId" => manifest.run_id,
      "testSteps" =>
        for step <- manifest.steps do
          %{"id" => test_step_id(id, step), "pickleStepId" => pickle_step_id(id, step)}
        end
    }
  end

  defp case_started(id) do
    %{
      "id" => started_id(id),
      "testCaseId" => "case:" <> id,
      "attempt" => 0,
      "timestamp" => @epoch
    }
  end

  defp case_finished(id),
    do: %{"testCaseStartedId" => started_id(id), "timestamp" => @epoch, "willBeRetried" => false}

  defp step_messages(id, {step, {status, message, exception, figures}}, embed?) do
    refs = %{"testCaseStartedId" => started_id(id), "testStepId" => test_step_id(id, step)}

    result =
      %{"status" => status, "duration" => %{"seconds" => 0, "nanos" => 0}}
      |> put_unless_nil("message", message)
      |> put_unless_nil("exception", exception)

    finished = Map.merge(refs, %{"testStepResult" => result, "timestamp" => @epoch})

    [%{"testStepStarted" => Map.put(refs, "timestamp", @epoch)}] ++
      Enum.map(figures, &%{attachment_key(embed?) => attachment(&1, refs, embed?)}) ++
      [%{"testStepFinished" => finished}]
  end

  defp attachment_key(true), do: "attachment"
  defp attachment_key(false), do: "externalAttachment"

  defp attachment({%Figure{} = figure, path, bytes}, refs, embed?) do
    base = Map.merge(refs, %{"mediaType" => media_type(figure.file), "timestamp" => @epoch})

    if embed? do
      Map.merge(base, %{
        "body" => Base.encode64(bytes),
        "contentEncoding" => "BASE64",
        "fileName" => figure.file
      })
    else
      Map.put(base, "url", "file://#{URI.encode(Path.expand(path))}#sha256=#{figure.file_sha256}")
    end
  end

  # {status, message, exception, verified figures}
  defp step_result(%Step{status: :skipped}, _dir), do: {"SKIPPED", nil, nil, []}

  defp step_result(%Step{status: :failed} = step, dir) do
    reason = step.error || "failed"
    exception = %{"type" => "StepFailed", "message" => reason}
    {"FAILED", detail(step, reason), exception, step |> figures(dir) |> elem(0)}
  end

  defp step_result(%Step{status: :errored} = step, dir) do
    reason = "errored: " <> (step.error || "no verdict")
    {"UNKNOWN", detail(step, reason), nil, step |> figures(dir) |> elem(0)}
  end

  defp step_result(%Step{status: :passed} = step, dir) do
    {verified, figure_problems} = figures(step, dir)

    problems =
      Enum.filter(
        [
          step.attempts != 1 && "attempts: #{step.attempts}; only a first-attempt pass counts",
          step.cursor == nil && "recorded no cursor window, so its assertions were not measured"
        ],
        &is_binary/1
      ) ++ figure_problems

    case problems do
      [] -> {"PASSED", nil, nil, verified}
      _ -> {"UNKNOWN", Enum.join(problems, "; "), nil, verified}
    end
  end

  defp detail(%Step{attempts: 1}, message), do: message
  defp detail(%Step{attempts: n}, message), do: "attempts: #{n}; #{message}"

  # The figures whose file is there and is the recorded one, and why the others are not.
  defp figures(%Step{figures: figures}, dir) do
    {ok, problems} =
      Enum.reduce(figures, {[], []}, fn figure, {ok, problems} ->
        path = Path.join(dir, figure.file)

        with {:ok, bytes} <- File.read(path),
             [] <- figure_problems(figure, bytes) do
          {[{figure, path, bytes} | ok], problems}
        else
          {:error, reason} ->
            {ok,
             ["figure #{figure.name} file is missing (#{:file.format_error(reason)})" | problems]}

          found ->
            {ok, Enum.map(found, &"figure #{figure.name} #{&1}") ++ problems}
        end
      end)

    {Enum.reverse(ok), Enum.reverse(problems)}
  end

  defp figure_problems(%Figure{} = figure, bytes) do
    Enum.filter(
      [
        not figure.settled && "was captured before the page settled",
        Enum.any?([figure.raster_sha256, figure.width, figure.height], &is_nil/1) &&
          "has no raster hash or size, so it was not measured",
        Json.sha256(bytes) != figure.file_sha256 && "file differs from its recorded sha256"
      ],
      &is_binary/1
    )
  end

  @doc """
  What a stream records, read back from its NDJSON: `%{run_success:, cases: [%{id:,
  steps: [%{name:, status:, message:, figures: [sha256]}]}]}`. Figure digests come
  from the `#sha256=` fragment of an external attachment's url, or from the bytes of
  an embedded one. `{:error, problems}` for bytes that are not a message stream.
  """
  @spec summary(binary()) :: {:ok, map()} | {:error, [String.t()]}
  def summary(ndjson) do
    ndjson
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, n}, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, %{} = envelope} -> {:cont, {:ok, [envelope | acc]}}
        _ -> {:halt, {:error, ["line #{n}: not a JSON object"]}}
      end
    end)
    |> case do
      {:ok, envelopes} -> {:ok, summarise(Enum.reverse(envelopes))}
      error -> error
    end
  end

  defp summarise(envelopes) do
    texts =
      for %{"pickle" => pickle} <- envelopes,
          step <- pickle["steps"],
          into: %{},
          do: {step["id"], step["text"]}

    steps =
      for %{"testCase" => test_case} <- envelopes,
          step <- test_case["testSteps"],
          into: %{},
          do: {step["id"], {test_case["id"], texts[step["pickleStepId"]]}}

    figures =
      Enum.group_by(
        for(
          envelope <- envelopes,
          {key, a} <- envelope,
          key in ["attachment", "externalAttachment"],
          do: {a["testStepId"], digest(a)}
        ),
        &elem(&1, 0),
        &elem(&1, 1)
      )

    finished =
      for %{"testStepFinished" => f} <- envelopes do
        {case_id, name} = steps[f["testStepId"]]

        {case_id,
         %{
           name: name,
           status: f["testStepResult"]["status"],
           message: f["testStepResult"]["message"],
           figures: Map.get(figures, f["testStepId"], [])
         }}
      end

    %{
      run_success:
        List.first(for %{"testRunFinished" => %{"success" => success}} <- envelopes, do: success),
      cases:
        for {case_id, group} <- Enum.group_by(finished, &elem(&1, 0), &elem(&1, 1)) do
          %{id: String.replace_prefix(case_id, "case:", ""), steps: group}
        end
    }
  end

  defp digest(%{"body" => body, "contentEncoding" => "BASE64"}),
    do: body |> Base.decode64!() |> Json.sha256()

  defp digest(%{"url" => url}),
    do: url |> URI.parse() |> Map.fetch!(:fragment) |> String.replace_prefix("sha256=", "")

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp media_type(file),
    do: Map.get(@media_types, Path.extname(file), "application/octet-stream")

  defp title(manifest), do: manifest.texts["title"] || manifest.journey

  # The step's first narration as the run resolved it, else its name.
  defp step_text(manifest, step) do
    prefix = step.name <> ".narration."

    manifest.texts
    |> Enum.flat_map(fn {key, text} ->
      with true <- String.starts_with?(key, prefix),
           {n, ""} <- key |> String.replace_prefix(prefix, "") |> Integer.parse() do
        [{n, text}]
      else
        _ -> []
      end
    end)
    |> case do
      [] -> step.name
      found -> found |> Enum.min_by(&elem(&1, 0)) |> elem(1)
    end
  end

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  defp uri(id), do: "journeys/#{id}.feature"
  defp started_id(id), do: "started:" <> id
  defp test_step_id(id, step), do: "step:#{id}/#{step.name}"
  defp pickle_step_id(id, step), do: "pickle-step:#{id}/#{step.name}"
end
