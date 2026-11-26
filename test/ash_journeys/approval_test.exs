defmodule AshJourneys.ApprovalTest do
  use ExUnit.Case, async: true

  alias AshJourneys.{Approval, Ir, Json, Lock, Manifest, Raster, Run}
  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"
  @people "find_the_person.people"
  @row "deactivate.deactivated"

  setup context do
    %{root: Runs.root(context), declared: Runs.declared()}
  end

  defp refused(root, declared, run_id) do
    assert {:error, problems} = Approval.approve(root, run_id, declared)
    refute File.exists?(Lock.path(root)), "a refused run wrote the lock"
    refute File.exists?(Path.join(root, "priv/journeys/en")), "a refused run published figures"
    problems
  end

  defp refuses(%{root: root, declared: declared}, edit, expected) do
    Runs.write!(root, declared, "r1", @journey, "en", edit: edit)
    problems = refused(root, declared, "r1")

    assert Enum.any?(problems, &(&1 =~ expected)),
           "expected #{inspect(expected)} in #{inspect(problems)}"

    problems
  end

  describe "a passing run" do
    test "is published byte for byte and the lock records its exact hashes", %{
      root: root,
      declared: declared
    } do
      dir = Runs.write!(root, declared, "r1", @journey, "en")
      Runs.write!(root, declared, "r1", @journey, "fr")

      assert {:ok, report} = Approval.approve(root, "r1", declared)
      assert report.pinned == %{name: "chromium", version: "141.0.7390.37"}

      assert [%{locale: "en", outcome: :approved}, %{locale: "fr", outcome: :approved}] =
               report.results

      assert [{@row, :added}, {@people, :added}] = hd(report.results).figures |> Enum.sort()

      approved = Lock.approved_dir(root, "en", @journey)

      assert File.read!(Path.join(approved, "manifest.json")) ==
               File.read!(Path.join(dir, "manifest.json"))

      assert File.read!(Path.join(approved, @people <> ".png")) ==
               File.read!(Path.join(dir, @people <> ".png"))

      lock = Runs.assert_lock_is_exact!(root)
      assert lock.browser == %{name: "chromium", version: "141.0.7390.37"}
      assert lock.tolerance == %{pixels: 32, channel_delta: 64}

      entry = lock.journeys[@journey]["en"]
      assert entry.run == "r1"
      assert entry.hash == declared[@journey].hash
      assert entry.environment == :test
      assert Map.keys(entry.figures) |> Enum.sort() == [@row, @people]
    end

    test "re-shot with identical rasters is kept, and no committed file changes", %{
      root: root,
      declared: declared
    } do
      Runs.write!(root, declared, "r1", @journey, "en")
      {:ok, _} = Approval.approve(root, "r1", declared)
      lock_bytes = File.read!(Lock.path(root))

      Runs.write!(root, declared, "r2", @journey, "en",
        edit: &%{&1 | commit: "fedcba9876543210fedcba9876543210fedcba98"}
      )

      assert {:ok, %{results: [%{outcome: :kept, figures: figures}]}} =
               Approval.approve(root, "r2", declared)

      assert Enum.all?(figures, &match?({_, :unchanged}, &1))
      assert File.read!(Lock.path(root)) == lock_bytes
    end

    test "re-shot with a corner wobble inside the tolerance is kept, with the approved run's exact hashes",
         %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      {:ok, _} = Approval.approve(root, "r1", declared)
      before = File.read!(Path.join(Lock.approved_dir(root, "en", @journey), @people <> ".png"))

      wobble = Runs.raster(40, 30, for(x <- 0..10, do: {x, 29, <<55, 40, 60, 255>>}))
      rasters = %{Runs.rasters(declared, @journey) | @people => wobble}
      Runs.write!(root, declared, "r2", @journey, "en", rasters: rasters)

      assert {:ok, %{results: [%{outcome: :kept, figures: figures}]}} =
               Approval.approve(root, "r2", declared)

      assert Enum.any?(
               figures,
               &match?({@people, {:within_tolerance, %{pixels: 11, max_delta: 35}}}, &1)
             )

      # The approved run stays whole: its file and its exact hash, never the wobbled one's.
      lock = Runs.assert_lock_is_exact!(root)
      assert lock.journeys[@journey]["en"].run == "r1"

      assert File.read!(Path.join(Lock.approved_dir(root, "en", @journey), @people <> ".png")) ==
               before

      refute lock.journeys[@journey]["en"].figures[@people].raster_sha256 == Raster.hash(wobble)
    end

    test "re-shot with a change beyond the tolerance replaces the approved run", %{
      root: root,
      declared: declared
    } do
      Runs.write!(root, declared, "r1", @journey, "en")
      {:ok, _} = Approval.approve(root, "r1", declared)

      changed = Runs.raster(40, 30, for(x <- 0..32, do: {x, 0, <<21, 40, 60, 255>>}))
      rasters = %{Runs.rasters(declared, @journey) | @people => changed}
      Runs.write!(root, declared, "r2", @journey, "en", rasters: rasters)

      assert {:ok, %{results: [%{outcome: :approved, figures: figures}]}} =
               Approval.approve(root, "r2", declared)

      assert Enum.any?(figures, &match?({@people, {:changed, %{pixels: 33, max_delta: 1}}}, &1))
      assert {@row, :unchanged} in figures

      lock = Runs.assert_lock_is_exact!(root)
      assert lock.journeys[@journey]["en"].run == "r2"
      assert lock.journeys[@journey]["en"].figures[@people].raster_sha256 == Raster.hash(changed)
    end

    test "a new declaration replaces its approved run even when every figure is alike", %{
      root: root,
      declared: declared
    } do
      Runs.write!(root, declared, "r1", @journey, "en")
      {:ok, _} = Approval.approve(root, "r1", declared)

      changed = changed_declaration(declared)
      Runs.write!(root, changed, "r2", @journey, "en")

      assert {:ok, %{results: [%{outcome: :approved, figures: figures}]}} =
               Approval.approve(root, "r2", changed)

      assert Enum.all?(figures, &match?({_, :unchanged}, &1))

      assert Runs.assert_lock_is_exact!(root).journeys[@journey]["en"].hash ==
               changed[@journey].hash
    end
  end

  describe "approve refuses, and writes nothing, for" do
    test "a failing run", context do
      refuses(context, &%{&1 | status: :failed}, "the run failed")
    end

    test "an errored run", context do
      refuses(context, &%{&1 | status: :errored}, "the run errored")
    end

    test "a run that needed a retry", context do
      refuses(
        context,
        &%{&1 | retries: 1},
        "the run needed 1 retry; only a pass on the first attempt is approvable"
      )
    end

    test "a step that passed on its second attempt", context do
      refuses(
        context,
        &Runs.step(&1, "deactivate", fn step -> %{step | attempts: 2} end),
        "step deactivate took 2 attempts"
      )
    end

    test "a run from a browser build other than the pinned one", %{root: root, declared: declared} do
      Lock.write!(%Lock{browser: %{name: "chromium", version: "140.0.7339.207"}}, root)
      Runs.write!(root, declared, "r1", @journey, "en")
      assert {:error, problems} = Approval.approve(root, "r1", declared)

      assert Enum.any?(
               problems,
               &(&1 =~
                   "the run is from chromium 141.0.7390.37, but the lock pins chromium 140.0.7339.207")
             )

      assert {:ok, %Lock{journeys: journeys}} = Lock.read(root)
      assert journeys == %{}
    end

    test "a run of a declaration other than the current one", %{root: root, declared: declared} do
      Runs.write!(root, changed_declaration(declared), "r1", @journey, "en")
      problems = refused(root, declared, "r1")
      assert Enum.any?(problems, &(&1 =~ "the run proves declaration")), inspect(problems)
    end

    test "a run that names another version", context do
      refuses(
        context,
        &%{&1 | version: 2},
        "the run is of version 2, but the journey is at version 1"
      )
    end

    test "a locale the journey does not declare", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "de")
      problems = refused(root, declared, "r1")

      assert "#{@journey}/de: the journey is not declared in locale de (it declares en, fr)" in problems
    end

    test "a journey no configured module declares", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      problems = refused(root, Map.delete(declared, @journey), "r1")
      assert "#{@journey}/en: no configured module declares journey #{@journey}" in problems
    end

    test "a failed, errored or skipped step", context do
      for status <- [:failed, :errored, :skipped] do
        refuses(
          context,
          &Runs.step(&1, "deactivate", fn step -> %{step | status: status, error: "boom"} end),
          "step deactivate #{status}: boom"
        )
      end
    end

    test "a missing step", context do
      refuses(
        context,
        &%{&1 | steps: Enum.reject(&1.steps, fn s -> s.name == "deactivate" end)},
        "step deactivate was not recorded"
      )
    end

    test "a step the journey does not declare", context do
      extra = %Manifest.Step{
        name: "bonus",
        actor: "admin",
        status: :passed,
        cursor: %{from: 0, to: 0}
      }

      refuses(context, &%{&1 | steps: &1.steps ++ [extra]}, "step bonus is not declared")
    end

    test "steps out of order", context do
      refuses(context, &%{&1 | steps: Enum.reverse(&1.steps)}, "not in the declared order")
    end

    test "a step run as another persona", context do
      refuses(
        context,
        &Runs.step(&1, "deactivate", fn step -> %{step | actor: "leaver"} end),
        "step deactivate ran as leaver, but the declaration says admin"
      )
    end

    test "an unmeasured step: no cursor window", context do
      refuses(
        context,
        &Runs.step(&1, "leaver_is_signed_in", fn step -> %{step | cursor: nil} end),
        "step leaver_is_signed_in recorded no cursor window"
      )
    end

    test "an unmeasured step: a trace expected but none recorded", context do
      for edit <- [&%{&1 | correlation_id: nil}, &%{&1 | span_ids: []}] do
        refuses(
          context,
          &Runs.step(&1, "deactivate", edit),
          "step deactivate expects a trace but recorded no correlation id"
        )
      end
    end

    test "an unsettled figure", context do
      refuses(
        context,
        &Runs.figure(&1, "find_the_person", "people", fn f -> %{f | settled: false} end),
        "figure people was captured before the page settled"
      )
    end

    test "an unmeasured figure: no raster hash", context do
      refuses(
        context,
        &Runs.figure(&1, "find_the_person", "people", fn f -> %{f | raster_sha256: nil} end),
        "figure people has no raster hash, so it was not measured"
      )
    end

    test "a declared figure not captured, or one captured that is not declared", context do
      refuses(
        context,
        &Runs.step(&1, "deactivate", fn s -> %{s | figures: []} end),
        "step deactivate did not capture figure deactivated"
      )

      refuses(
        context,
        &Runs.figure(&1, "deactivate", "deactivated", fn f -> %{f | name: "other"} end),
        "captured figure other, which it does not declare"
      )
    end

    test "a figure captured twice", context do
      refuses(
        context,
        &Runs.step(&1, "deactivate", fn s -> %{s | figures: s.figures ++ s.figures} end),
        "captured figure deactivated twice"
      )
    end

    test "a highlight declared but not recorded, or recorded but not declared", context do
      refuses(
        context,
        &Runs.figure(&1, "find_the_person", "people", fn f -> %{f | highlight: nil} end),
        "figure people declares a highlight but recorded no highlight box"
      )

      refuses(
        context,
        &Runs.figure(&1, "deactivate", "deactivated", fn f ->
          %{f | highlight: %{x: 0, y: 0, width: 1, height: 1}}
        end),
        "figure deactivated recorded a highlight box but declares no highlight"
      )
    end

    test "a figure whose file is missing", %{root: root, declared: declared} do
      dir = Runs.write!(root, declared, "r1", @journey, "en")
      File.rm!(Path.join(dir, @people <> ".png"))
      problems = refused(root, declared, "r1")

      assert Enum.any?(problems, &(&1 =~ "figure people file #{@people}.png cannot be read")),
             inspect(problems)
    end

    test "a figure whose bytes, pixels or size are not what the manifest says", context do
      other = Runs.raster(40, 30, [{0, 0, <<0, 0, 0, 255>>}])

      refuses(
        context,
        &Runs.figure(&1, "find_the_person", "people", fn f ->
          %{f | file_sha256: Json.sha256("x")}
        end),
        "has its file's sha256"
      )

      refuses(
        context,
        &Runs.figure(&1, "find_the_person", "people", fn f ->
          %{f | raster_sha256: Raster.hash(other)}
        end),
        "has raster hash"
      )

      refuses(
        context,
        &Runs.figure(&1, "find_the_person", "people", fn f -> %{f | width: 41} end),
        "is 40x30, but the manifest says 41x30"
      )
    end

    test "a figure file that is not a PNG", %{root: root, declared: declared} do
      dir = Runs.write!(root, declared, "r1", @journey, "en")
      path = Path.join(dir, "manifest.json")
      {:ok, manifest} = Manifest.read(path)
      File.write!(Path.join(dir, @people <> ".png"), "not a png")

      manifest
      |> Runs.figure("find_the_person", "people", &%{&1 | file_sha256: Json.sha256("not a png")})
      |> Manifest.write!(dir)

      problems = refused(root, declared, "r1")

      assert Enum.any?(problems, &(&1 =~ "figure people file does not decode: not a PNG")),
             inspect(problems)
    end

    test "a missing manifest", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      dir = Runs.write!(root, declared, "r1", @journey, "fr")
      File.rm!(Path.join(dir, "manifest.json"))

      problems = refused(root, declared, "r1")

      assert Enum.any?(problems, &(&1 =~ "#{@journey}/fr:" and &1 =~ "no manifest")),
             inspect(problems)
    end

    test "a journey directory with no locale under it", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      File.mkdir_p!(Path.join(Run.dir(root, "r1"), "remove_a_person"))
      problems = refused(root, declared, "r1")

      assert Enum.any?(problems, &(&1 =~ "remove_a_person/(none):" and &1 =~ "no manifest")),
             inspect(problems)
    end

    test "a malformed manifest", %{root: root, declared: declared} do
      dir = Runs.write!(root, declared, "r1", @journey, "en")
      File.write!(Path.join(dir, "manifest.json"), ~s({"format": 2, "status": "passed"}))
      problems = refused(root, declared, "r1")
      assert "#{@journey}/en: manifest.steps: missing" in problems

      File.write!(Path.join(dir, "manifest.json"), "{")
      assert [problem] = refused(root, declared, "r1")
      assert problem =~ "#{@journey}/en: manifest: not JSON"
    end

    test "a manifest filed under another run, journey or locale", context do
      refuses(
        context,
        &%{&1 | run_id: "r0"},
        ~s(manifest.run_id is "r0", but it was found under "r1")
      )

      refuses(
        context,
        &%{&1 | locale: "fr"},
        ~s(manifest.locale is "fr", but it was found under "en")
      )
    end

    test "a run that mixes browser builds", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")

      Runs.write!(root, declared, "r1", @journey, "fr",
        edit: &%{&1 | browser: %{&1.browser | version: "151.0.7922.108"}}
      )

      problems = refused(root, declared, "r1")
      assert Enum.any?(problems, &(&1 =~ "the run mixes browser builds")), inspect(problems)
    end

    test "a whole run when only one of its candidates is bad", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      Runs.write!(root, declared, "r1", @journey, "fr", edit: &%{&1 | status: :failed})
      assert [problem] = refused(root, declared, "r1")
      assert problem == "#{@journey}/fr: the run failed"
    end

    test "a run that does not exist, is empty or is not a run id", %{
      root: root,
      declared: declared
    } do
      assert ["no run r9" <> _] = refused(root, declared, "r9")
      File.mkdir_p!(Run.dir(root, "r9"))
      assert ["run r9 holds no journeys"] = refused(root, declared, "r9")
      assert [~s("../r9" is not a run id)] = refused(root, declared, "../r9")
    end

    test "any run while the lock does not read", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      File.mkdir_p!(Path.dirname(Lock.path(root)))

      File.write!(
        Lock.path(root),
        ~s({"format": 1, "browser": null, "tolerance": {"pixels": 32}, "journeys": {}})
      )

      assert {:error, problems} = Approval.approve(root, "r1", declared)
      assert Enum.any?(problems, &(&1 =~ "tolerance.channel_delta: missing"))
    end

    test "every problem at once", context do
      problems =
        refuses(
          context,
          fn manifest ->
            manifest
            |> Map.put(:retries, 2)
            |> Runs.step("deactivate", &%{&1 | attempts: 3, status: :failed})
            |> Runs.figure("find_the_person", "people", &%{&1 | settled: false})
          end,
          "the run needed 2 retries"
        )

      assert length(problems) >= 4
    end
  end

  # The same journey with one changed word: a new declaration hash.
  defp changed_declaration(declared) do
    ir = Map.put(declared[@journey].ir, "title", "Revoke the access of a leaver")
    assert Ir.hash(ir) != declared[@journey].hash
    %{declared | @journey => %{declared[@journey] | ir: ir, hash: Ir.hash(ir)}}
  end
end
