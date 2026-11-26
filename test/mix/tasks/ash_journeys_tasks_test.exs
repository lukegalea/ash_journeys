defmodule Mix.Tasks.AshJourneysTasksTest do
  # The tasks read the working directory and the application environment.
  use ExUnit.Case, async: false

  alias AshJourneys.{Lock, Raster}
  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"

  setup context do
    root = Runs.root(context)
    previous = Application.get_env(:ash_journeys, :journeys)
    Application.put_env(:ash_journeys, :journeys, [AshJourneys.Test.Offboarding])
    Mix.shell(Mix.Shell.Process)
    cwd = File.cwd!()
    File.cd!(root)

    on_exit(fn ->
      File.cd!(cwd)
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: Application.put_env(:ash_journeys, :journeys, previous),
        else: Application.delete_env(:ash_journeys, :journeys)
    end)

    %{root: root, declared: Runs.declared()}
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> message
    after
      0 -> flunk("the task printed nothing")
    end
  end

  test "approve publishes a run, lock reports it current and --check passes", %{
    root: root,
    declared: declared
  } do
    Runs.write!(root, declared, "r1", @journey, "en")

    Mix.Task.rerun("ash_journeys.approve", ["r1"])
    assert output() =~ "pinned chromium 141.0.7390.37 in the lock"
    assert File.exists?(Path.join(root, "priv/journeys/en/#{@journey}/manifest.json"))

    Mix.Task.rerun("ash_journeys.lock", ["--check"])
    message = output()
    assert message =~ "current     #{@journey} en"
    assert message =~ "unapproved  #{@journey} fr"
    assert message =~ "unapproved  remove_a_person en"
  end

  test "lock --check fails when a declaration is newer than its approved run, and plain lock does not",
       %{root: root, declared: declared} do
    Runs.write!(root, declared, "r1", @journey, "en")
    Mix.Task.rerun("ash_journeys.approve", ["r1"])
    _ = output()

    {:ok, lock} = Lock.read(root)
    stale = put_in(lock.journeys[@journey]["en"].hash, String.duplicate("b", 64))
    Lock.write!(stale, root)

    Mix.Task.rerun("ash_journeys.lock", [])

    assert output() =~
             "stale       #{@journey} en: stale; the approved run proves bbbbbbbbbbbb"

    assert_raise Mix.Error, ~r/1 journey\(s\) are not proven by their approved run/, fn ->
      Mix.Task.rerun("ash_journeys.lock", ["--check"])
    end
  end

  test "lock --check passes with nothing approved, and stops on a lock that does not read", %{
    root: root
  } do
    Mix.Task.rerun("ash_journeys.lock", ["--check"])
    assert output() =~ "ash_journeys.lock: 2 journey(s) declared"

    File.mkdir_p!(Path.dirname(Lock.path(root)))
    File.write!(Lock.path(root), "{")

    assert_raise Mix.Error, ~r/the lock does not read/, fn ->
      Mix.Task.rerun("ash_journeys.lock", ["--check"])
    end
  end

  test "approve refuses a run with every reason and writes nothing", %{
    root: root,
    declared: declared
  } do
    Runs.write!(root, declared, "r1", @journey, "en", edit: &%{&1 | status: :failed, retries: 1})

    error = assert_raise Mix.Error, fn -> Mix.Task.rerun("ash_journeys.approve", ["r1"]) end
    assert error.message =~ "run r1 is not approvable"
    assert error.message =~ "  #{@journey}/en: the run failed"
    assert error.message =~ "  #{@journey}/en: the run needed 1 retry"
    refute File.exists?(Lock.path(root))
  end

  test "impact prints the comparison and fails a run approve would refuse", %{
    root: root,
    declared: declared
  } do
    Runs.write!(root, declared, "r1", @journey, "en")
    Mix.Task.rerun("ash_journeys.approve", ["r1"])
    _ = output()

    rasters = %{
      Runs.rasters(declared, @journey)
      | "find_the_person.people" => Runs.raster(40, 30, [], <<0, 0, 0, 255>>)
    }

    Runs.write!(root, declared, "r2", @journey, "en", rasters: rasters)
    Mix.Task.rerun("ash_journeys.impact", ["r2"])
    message = output()
    assert message =~ "#{@journey} en: approvable"

    assert message =~
             "find_the_person.people: changed (1200 px, channel delta up to 60 in 40x30 at 0,0)"

    assert message =~
             "side by side: tmp/journeys/impact/r2/#{@journey}/en/find_the_person.people.png"

    assert {:ok, %Raster{}} =
             Raster.decode(
               File.read!("tmp/journeys/impact/r2/#{@journey}/en/find_the_person.people.png")
             )

    Runs.write!(root, declared, "r3", @journey, "en",
      edit: &Runs.step(&1, "deactivate", fn s -> %{s | attempts: 2} end)
    )

    assert_raise Mix.Error, ~r/run r3 is not approvable/, fn ->
      Mix.Task.rerun("ash_journeys.impact", ["r3"])
    end

    assert output() =~ "refused: #{@journey}/en: step deactivate took 2 attempts"
  end

  test "the tasks refuse bad arguments" do
    assert_raise Mix.Error, ~r/usage: mix ash_journeys.approve <run-id>/, fn ->
      Mix.Task.rerun("ash_journeys.approve", [])
    end

    assert_raise Mix.Error, ~r/usage: mix ash_journeys.impact <run-id>/, fn ->
      Mix.Task.rerun("ash_journeys.impact", ["a", "b"])
    end

    assert_raise Mix.Error, ~r/usage: mix ash_journeys.lock/, fn ->
      Mix.Task.rerun("ash_journeys.lock", ["--fix"])
    end
  end
end
