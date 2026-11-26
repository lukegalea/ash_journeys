defmodule AshJourneys.MessagesTest do
  use ExUnit.Case, async: true

  alias AshJourneys.{Json, Manifest, Messages, Run}
  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"
  @fixtures Path.expand("../fixtures/cucumber_messages", __DIR__)
  @schema_file Path.join(@fixtures, "messages.schema.json")
  @people "find_the_person.people"

  setup_all do
    {:ok, root} = @schema_file |> File.read!() |> Jason.decode!() |> JSV.build()
    %{validator: root}
  end

  setup context do
    %{root: Runs.root(context), declared: Runs.declared(), validator: context.validator}
  end

  # One run of the offboarding journey in en and fr, each manifest changed by `edit`.
  defp write_run!(root, declared, edit \\ & &1) do
    for locale <- ["en", "fr"],
        do: Runs.write!(root, declared, "r1", @journey, locale, edit: edit)

    Run.dir(root, "r1")
  end

  defp messages!(dir, opts \\ []) do
    assert {:ok, candidates} = Messages.candidates(dir)
    Messages.build(candidates, opts)
  end

  defp assert_valid!(%{validator: validator}, messages) do
    for message <- messages do
      # Through JSON, as a reader of the NDJSON sees it.
      data = message |> Jason.encode!() |> Jason.decode!()

      case JSV.validate(data, validator) do
        {:ok, _} -> :ok
        {:error, error} -> flunk("invalid #{inspect(message)}: #{Exception.message(error)}")
      end
    end
  end

  defp finished(messages) do
    for %{"testStepFinished" => f} <- messages,
        do: {f["testStepId"], f["testStepResult"]}
  end

  defp success?(messages),
    do: Enum.find_value(messages, &get_in(&1, ["testRunFinished", "success"]))

  defp status(messages, step_name) do
    {_id, result} =
      Enum.find(finished(messages), fn {id, _} -> String.ends_with?(id, "/" <> step_name) end)

    result
  end

  describe "the pinned schema" do
    test "is the one recorded, at the version the export follows" do
      version = File.read!(Path.join(@fixtures, "VERSION.md"))
      sha = Json.sha256(File.read!(@schema_file))

      assert version =~ "sha256: `#{sha}`"
      assert version =~ "Protocol version #{Messages.protocol_version()}"
      assert version =~ "Licence: MIT"
      assert File.read!(Path.join(@fixtures, "LICENSE")) =~ "MIT License"
    end

    test "rejects a status it does not define", ctx do
      bad = %{
        "testStepFinished" => %{
          "testCaseStartedId" => "a",
          "testStepId" => "b",
          "timestamp" => %{"seconds" => 0, "nanos" => 0},
          "testStepResult" => %{
            "status" => "PASSEDISH",
            "duration" => %{"seconds" => 0, "nanos" => 0}
          }
        }
      }

      assert_raise ExUnit.AssertionError, fn -> assert_valid!(ctx, [bad]) end
    end
  end

  describe "a clean run" do
    test "every message validates, referenced or embedded",
         %{root: root, declared: declared} = ctx do
      dir = write_run!(root, declared)

      for opts <- [[], [embed: true]] do
        messages = messages!(dir, opts)
        assert_valid!(ctx, messages)

        # And as the NDJSON a reader gets, line by line.
        lines = messages |> Messages.encode() |> String.split("\n", trim: true)
        assert length(lines) == length(messages)
        assert_valid!(ctx, Enum.map(lines, &Jason.decode!/1))
      end
    end

    test "passes every step, and the run", %{root: root, declared: declared} do
      messages = messages!(write_run!(root, declared))

      assert success?(messages)
      assert [%{"meta" => _}, %{"testRunStarted" => _} | _] = messages
      assert %{"testRunFinished" => finished} = List.last(messages)
      refute Map.has_key?(finished, "message")
      assert finished(messages) |> Enum.all?(fn {_, result} -> result["status"] == "PASSED" end)
    end

    test "round-trips the step count, statuses and figure hashes", %{
      root: root,
      declared: declared
    } do
      dir = write_run!(root, declared)
      {:ok, candidates} = Messages.candidates(dir)

      for opts <- [[], [embed: true]] do
        ndjson = candidates |> Messages.build(opts) |> Messages.encode()
        assert {:ok, %{run_success: true, cases: cases}} = Messages.summary(ndjson)

        for %{manifest: manifest} <- candidates do
          assert %{steps: steps} = Enum.find(cases, &(&1.id == "#{@journey}/#{manifest.locale}"))
          assert length(steps) == length(manifest.steps)
          assert Enum.all?(steps, &(&1.status == "PASSED"))

          expected = for step <- manifest.steps, f <- step.figures, do: f.file_sha256
          assert expected != []
          assert Enum.sort(Enum.flat_map(steps, & &1.figures)) == Enum.sort(expected)
        end
      end
    end

    test "is the same bytes every time, in the run's own language", %{
      root: root,
      declared: declared
    } do
      dir = write_run!(root, declared)
      assert Messages.encode(messages!(dir)) == Messages.encode(messages!(dir))

      fr = for %{"pickle" => %{"language" => "fr"} = pickle} <- messages!(dir), do: pickle
      assert [%{"name" => "Révoquer l'accès d'une personne qui part"}] = fr
    end
  end

  describe "never reported as a pass" do
    test "a retried step says its attempts, and the run is not clean",
         %{root: root, declared: declared} = ctx do
      dir =
        write_run!(root, declared, &Runs.step(&1, "deactivate", fn s -> %{s | attempts: 3} end))

      messages = messages!(dir)

      assert_valid!(ctx, messages)
      assert %{"status" => "UNKNOWN", "message" => message} = status(messages, "deactivate")
      assert message =~ "attempts: 3"
      refute success?(messages)
      assert %{"testRunFinished" => %{"message" => run}} = List.last(messages)
      assert run =~ "step deactivate is UNKNOWN"
      assert {:ok, %{run_success: false}} = Messages.summary(Messages.encode(messages))
    end

    test "a run that needed a retry is not clean though every step passed first time",
         %{root: root, declared: declared} = ctx do
      messages = messages!(write_run!(root, declared, &%{&1 | retries: 1}))

      assert_valid!(ctx, messages)
      assert finished(messages) |> Enum.all?(fn {_, r} -> r["status"] == "PASSED" end)
      refute success?(messages)
    end

    test "a failed run is not clean though every step passed", %{root: root, declared: declared} do
      refute success?(messages!(write_run!(root, declared, &%{&1 | status: :failed})))
    end

    test "an errored step is UNKNOWN, a failed one FAILED, a skipped one SKIPPED",
         %{root: root, declared: declared} = ctx do
      edit = fn manifest ->
        manifest
        |> Runs.step("find_the_person", &%{&1 | status: :errored, error: "browser crashed"})
        |> Runs.step("deactivate", &%{&1 | status: :failed, error: "no dialog"})
        |> Runs.step("their_session_is_dead", &%{&1 | status: :skipped})
        |> Map.put(:status, :errored)
      end

      messages = messages!(write_run!(root, declared, edit))

      assert_valid!(ctx, messages)

      assert %{"status" => "UNKNOWN", "message" => "errored: browser crashed"} =
               status(messages, "find_the_person")

      assert %{"status" => "FAILED", "exception" => %{"message" => "no dialog"}} =
               status(messages, "deactivate")

      assert %{"status" => "SKIPPED"} = status(messages, "their_session_is_dead")
      assert %{"status" => "PASSED"} = status(messages, "leaver_is_signed_in")
      refute success?(messages)
    end

    test "a step with no cursor window is unmeasured", %{root: root, declared: declared} = ctx do
      messages =
        messages!(
          write_run!(root, declared, &Runs.step(&1, "deactivate", fn s -> %{s | cursor: nil} end))
        )

      assert_valid!(ctx, messages)
      assert %{"status" => "UNKNOWN", "message" => message} = status(messages, "deactivate")
      assert message =~ "not measured"
      refute success?(messages)
    end

    for {name, change, reason} <- [
          {"a figure with no raster hash", quote(do: &%{&1 | raster_sha256: nil}),
           "not measured"},
          {"a figure with no size", quote(do: &%{&1 | width: nil}), "not measured"},
          {"a figure captured before the page settled", quote(do: &%{&1 | settled: false}),
           "before the page settled"}
        ] do
      test "#{name} is unmeasured", %{root: root, declared: declared} = ctx do
        change = unquote(change)
        edit = &Runs.figure(&1, "find_the_person", "people", change)
        messages = messages!(write_run!(root, declared, edit))

        assert_valid!(ctx, messages)

        assert %{"status" => "UNKNOWN", "message" => message} =
                 status(messages, "find_the_person")

        assert message =~ unquote(reason)
        refute success?(messages)
      end
    end

    test "a missing figure file is unmeasured and attached to nothing",
         %{root: root, declared: declared} = ctx do
      dir = write_run!(root, declared)
      File.rm!(Path.join([dir, @journey, "en", @people <> ".png"]))
      messages = messages!(dir)

      assert_valid!(ctx, messages)
      assert %{"status" => "UNKNOWN", "message" => message} = status(messages, "find_the_person")
      assert message =~ "file is missing"
      refute success?(messages)
      assert {:ok, %{cases: cases}} = Messages.summary(Messages.encode(messages))
      en_case = Enum.find(cases, &(&1.id == "#{@journey}/en"))
      fr_case = Enum.find(cases, &(&1.id == "#{@journey}/fr"))
      assert Enum.find(en_case.steps, &(&1.status == "UNKNOWN")).figures == []
      assert Enum.all?(fr_case.steps, &(&1.status == "PASSED"))
    end

    test "a figure file that is not the recorded one is unmeasured and not attached",
         %{root: root, declared: declared} = ctx do
      dir = write_run!(root, declared)
      File.write!(Path.join([dir, @journey, "en", @people <> ".png"]), "not the figure")
      messages = messages!(dir, embed: true)

      assert_valid!(ctx, messages)
      assert %{"status" => "UNKNOWN", "message" => message} = status(messages, "find_the_person")
      assert message =~ "differs from its recorded sha256"

      refute Enum.any?(
               messages,
               &match?(
                 %{
                   "attachment" => %{
                     "fileName" => @people <> ".png",
                     "body" => "bm90IHRoZSBmaWd1cmU="
                   }
                 },
                 &1
               )
             )

      refute success?(messages)
    end

    test "a manifest with no steps is not a pass", %{root: root, declared: declared} = ctx do
      messages = messages!(write_run!(root, declared, &%{&1 | steps: []}))

      assert_valid!(ctx, messages)
      refute success?(messages)
      assert %{"testRunFinished" => %{"message" => message}} = List.last(messages)
      assert message =~ "recorded no steps"
    end
  end

  describe "exports nothing" do
    test "for a run that does not exist", %{root: root} do
      assert {:error, [problem]} = Messages.candidates(Run.dir(root, "nope"))
      assert problem =~ "does not exist"
    end

    test "for a run with no journeys", %{root: root} do
      File.mkdir_p!(Run.dir(root, "empty"))
      assert {:error, [problem]} = Messages.candidates(Run.dir(root, "empty"))
      assert problem =~ "holds no journeys"
    end

    test "for a missing manifest", %{root: root, declared: declared} do
      dir = write_run!(root, declared)
      File.rm!(Path.join([dir, @journey, "fr", Manifest.file_name()]))
      assert {:error, [problem]} = Messages.candidates(dir)
      assert problem =~ "no manifest"
    end

    test "for a malformed manifest, whole", %{root: root, declared: declared} do
      dir = write_run!(root, declared)
      File.write!(Path.join([dir, @journey, "en", Manifest.file_name()]), ~s({"format": 2}))
      assert {:error, problems} = Messages.candidates(dir)
      assert "manifest.run_id: missing" in problems
    end

    test "for a manifest that is not JSON", %{root: root, declared: declared} do
      dir = write_run!(root, declared)
      File.write!(Path.join([dir, @journey, "en", Manifest.file_name()]), "{nope")
      assert {:error, [problem]} = Messages.candidates(dir)
      assert problem =~ "not JSON"
    end
  end

  describe "mix ash_journeys.export.messages" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "writes the stream to a file", %{root: root, declared: declared} = ctx do
      dir = write_run!(root, declared)
      out = Path.join(root, "run.ndjson")

      Mix.Task.rerun("ash_journeys.export.messages", [dir, "--out", out])

      lines = out |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) > 10
      assert_valid!(ctx, Enum.map(lines, &Jason.decode!/1))
      assert List.last(lines) =~ ~s("success":true)
    end

    test "prints the stream without --out", %{root: root, declared: declared} do
      Mix.Task.rerun("ash_journeys.export.messages", [write_run!(root, declared), "--embed"])
      assert_received {:mix_shell, :info, [ndjson]}
      assert ndjson =~ ~s("contentEncoding":"BASE64")
    end

    test "writes nothing and raises for a run it cannot read", %{root: root, declared: declared} do
      dir = write_run!(root, declared)
      File.rm!(Path.join([dir, @journey, "fr", Manifest.file_name()]))
      out = Path.join(root, "never.ndjson")

      assert_raise Mix.Error, ~r/nothing was exported\n  .*no manifest/, fn ->
        Mix.Task.rerun("ash_journeys.export.messages", [dir, "--out", out])
      end

      refute File.exists?(out)
    end

    test "wants one run directory" do
      assert_raise Mix.Error, ~r/usage/, fn ->
        Mix.Task.rerun("ash_journeys.export.messages", [])
      end
    end
  end
end
