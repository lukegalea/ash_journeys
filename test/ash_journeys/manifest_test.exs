defmodule AshJourneys.ManifestTest do
  use ExUnit.Case, async: true

  alias AshJourneys.Manifest
  alias AshJourneys.Test.Runs

  setup context do
    declared = Runs.declared()
    rasters = Runs.rasters(declared, "revoke_a_leavers_access")
    manifest = Runs.manifest(declared, "r1", "revoke_a_leavers_access", "en", rasters)
    %{root: Runs.root(context), manifest: manifest, json: Manifest.to_json(manifest)}
  end

  test "write!/2 and read/1 round-trip every field", %{root: root, manifest: manifest} do
    path = Manifest.write!(manifest, root)
    assert Path.basename(path) == "manifest.json"
    assert {:ok, ^manifest} = Manifest.read(path)
  end

  test "the file is pretty JSON with sorted keys, so its diff shows only what changed", %{
    manifest: manifest
  } do
    bytes = Manifest.encode(manifest)
    assert String.ends_with?(bytes, "}\n")
    keys = Regex.scan(~r/^  "(\w+)":/m, bytes) |> Enum.map(&List.last/1)
    assert keys == Enum.sort(keys)
    assert Manifest.encode(manifest) == bytes
  end

  test "records what the run and each step need", %{manifest: manifest} do
    assert %{name: "chromium", version: _, executable: _} = manifest.browser
    assert manifest.environment == :test

    step = Enum.find(manifest.steps, &(&1.name == "deactivate"))

    assert %{actor: "admin", attempts: 1, cursor: %{from: _, to: _}, correlation_id: "corr-2"} =
             step

    assert [%{name: "deactivated", settled: true, file_sha256: _, raster_sha256: _}] =
             step.figures
  end

  describe "read/1 never reads a bad manifest as a manifest" do
    test "a missing file", %{root: root} do
      assert {:error, [problem]} = Manifest.read(Path.join(root, "manifest.json"))
      assert problem =~ "no manifest"
    end

    test "bytes that are not JSON, or not an object" do
      assert {:error, ["manifest: not JSON" <> _]} = Manifest.decode("{\"format\": 1,")
      assert {:error, ["manifest: expected a JSON object"]} = Manifest.decode("[]")
      assert {:error, ["manifest: expected a JSON object"]} = Manifest.from_json("1")
    end

    test "another format", %{json: json} do
      assert {:error, ["manifest.format: expected 2, got 1"]} =
               Manifest.from_json(%{json | "format" => 1})

      assert {:error, ["manifest.format: missing"]} =
               Manifest.from_json(Map.delete(json, "format"))
    end

    test "every missing field, with its path", %{json: json} do
      assert {:error, problems} =
               Manifest.from_json(Map.drop(json, ["commit", "browser", "status"]))

      assert "manifest.commit: missing" in problems
      assert "manifest.browser: missing" in problems
      assert "manifest.status: missing" in problems

      step = json["steps"] |> hd() |> Map.delete("attempts")

      assert {:error, ["manifest.steps[0].attempts: missing"]} =
               Manifest.from_json(%{json | "steps" => [step | tl(json["steps"])]})
    end

    test "unknown keys", %{json: json} do
      assert {:error, ["manifest.retried: unknown key"]} =
               Manifest.from_json(Map.put(json, "retried", true))
    end

    test "values of the wrong kind", %{json: json} do
      cases = [
        {"status", "green", "manifest.status: expected one of errored, failed, passed"},
        {"environment", "prod", "manifest.environment: expected one of operated, staging, test"},
        {"declaration_hash", "abc", "manifest.declaration_hash: expected a sha256"},
        {"retries", -1, "manifest.retries: expected an integer >= 0"},
        {"version", 0, "manifest.version: expected an integer >= 1"},
        {"steps", %{}, "manifest.steps: expected a list"},
        {"browser", %{"name" => "chromium", "version" => "1"},
         "manifest.browser.executable: missing"}
      ]

      for {key, value, expected} <- cases do
        assert {:error, [problem]} = Manifest.from_json(%{json | key => value})
        assert String.starts_with?(problem, expected), "#{key}: #{problem}"
      end
    end

    test "a step or figure that is malformed", %{json: json} do
      [first, second | rest] = json["steps"]
      [figure] = second["figures"]

      bad = [
        {%{first | "status" => "unmeasured"}, "manifest.steps[0].status: expected one of"},
        {%{first | "attempts" => 0}, "manifest.steps[0].attempts: expected an integer >= 1"},
        {%{first | "cursor" => %{"from" => 5, "to" => 2}},
         "manifest.steps[0].cursor: from (5) is after to (2)"},
        {%{first | "span_ids" => [""]},
         "manifest.steps[0].span_ids[0]: expected a non-empty string"}
      ]

      for {step, expected} <- bad do
        assert {:error, [problem]} =
                 Manifest.from_json(%{json | "steps" => [step, second | rest]})

        assert String.starts_with?(problem, expected), problem
      end

      bad_figures = [
        {%{figure | "file" => "../escape.png"},
         "manifest.steps[1].figures[0].file: expected a plain file name"},
        {%{figure | "file" => "sub/figure.png"},
         "manifest.steps[1].figures[0].file: expected a plain file name"},
        {%{figure | "file" => ".hidden.png"},
         "manifest.steps[1].figures[0].file: expected a plain file name"},
        {%{figure | "file_sha256" => nil},
         "manifest.steps[1].figures[0].file_sha256: expected a sha256"},
        {%{figure | "settled" => "yes"},
         "manifest.steps[1].figures[0].settled: expected a boolean"},
        {%{figure | "highlight" => %{"x" => 0, "y" => 0, "width" => 0, "height" => 4}},
         "manifest.steps[1].figures[0].highlight.width: expected a number > 0"}
      ]

      for {figure, expected} <- bad_figures do
        step = %{second | "figures" => [figure]}
        assert {:error, [problem]} = Manifest.from_json(%{json | "steps" => [first, step | rest]})
        assert String.starts_with?(problem, expected), problem
      end
    end

    test "an :operated run with figures: figures come only from a seeded world", %{json: json} do
      assert {:error, [problem]} = Manifest.from_json(%{json | "environment" => "operated"})
      assert problem =~ "an :operated run records no figures"

      no_figures = Enum.map(json["steps"], &%{&1 | "figures" => []})

      assert {:ok, %{environment: :operated}} =
               Manifest.from_json(%{json | "environment" => "operated", "steps" => no_figures})
    end
  end
end
