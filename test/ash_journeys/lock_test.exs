defmodule AshJourneys.LockTest do
  use ExUnit.Case, async: true

  alias AshJourneys.{Approval, Lock}
  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"

  setup context do
    %{root: Runs.root(context), declared: Runs.declared()}
  end

  defp approved(root, declared) do
    Runs.write!(root, declared, "r1", @journey, "en")
    {:ok, _} = Approval.approve(root, "r1", declared)
    {:ok, lock} = Lock.read(root)
    lock
  end

  describe "check/2" do
    test "an approved run of the current declaration is current; the rest is unapproved", %{
      root: root,
      declared: declared
    } do
      status = Lock.check(approved(root, declared), declared)

      assert status.current == [{@journey, "en"}]
      assert status.unapproved == [{"remove_a_person", "en"}, {@journey, "fr"}]
      assert status.stale == []
      assert status.orphaned == []
    end

    test "a declaration that changed after its run was approved is stale", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      approved_hash = declared[@journey].hash
      changed = put_in(declared, [@journey, :hash], String.duplicate("a", 64))

      assert %{stale: [{@journey, "en", ^approved_hash, "aaaa" <> _}], current: []} =
               Lock.check(lock, changed)
    end

    test "nothing but a changed declaration is stale", %{root: root, declared: declared} do
      lock = approved(root, declared)

      # Another tolerance, another pinned build, figures deleted from priv, an entry
      # for a journey no longer declared: reported, never stale.
      lock = %{
        lock
        | tolerance: %{pixels: 0, channel_delta: 0},
          browser: %{name: "chromium", version: "999"},
          journeys: Map.put(lock.journeys, "gone", lock.journeys[@journey])
      }

      File.rm_rf!(Lock.approved_dir(root, "en", @journey))
      status = Lock.check(lock, declared)

      assert status.stale == []
      assert status.orphaned == [{"gone", "en"}]
      assert status.current == [{@journey, "en"}]
    end

    test "an entry for a locale the journey no longer declares is orphaned", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      fewer = put_in(declared, [@journey, :ir, "locales"], ["fr"])

      assert %{orphaned: [{@journey, "en"}], stale: [], unapproved: [{@journey, "fr"}]} =
               Lock.check(lock, Map.take(fewer, [@journey]))
    end
  end

  describe "read/1" do
    test "a missing lock is empty, with the default tolerance", %{root: root} do
      assert {:ok,
              %Lock{browser: nil, journeys: %{}, tolerance: %{pixels: 32, channel_delta: 64}}} =
               Lock.read(root)
    end

    test "write!/2 and read/1 round-trip", %{root: root, declared: declared} do
      lock = approved(root, declared)
      Lock.write!(lock, root)
      assert {:ok, ^lock} = Lock.read(root)
    end

    test "a malformed lock reads as problems, never as an empty lock", %{root: root} do
      File.mkdir_p!(Path.dirname(Lock.path(root)))

      for {json, expected} <- [
            {"{", "not JSON"},
            {"[]", "expected a JSON object"},
            {~s({"format": 2}), "format: expected 1"},
            {~s({"format": 1, "browser": null, "tolerance": {"pixels": 32, "channel_delta": 300}, "journeys": {}}),
             "tolerance.channel_delta: expected an integer from 0 to 255"},
            {~s({"format": 1, "browser": null, "tolerance": {"pixels": -1, "channel_delta": 64}, "journeys": {}}),
             "tolerance.pixels: expected an integer >= 0"},
            {~s({"format": 1, "browser": null, "tolerance": {"pixels": 1, "channel_delta": 1}, "journeys": {"j": {"en": {"run": "r1"}}}}),
             "journeys.j.en.commit: missing"},
            {~s({"format": 1, "browser": null, "tolerance": {"pixels": 1, "channel_delta": 1}, "journeys": {}, "extra": 1}),
             "extra: unknown key"}
          ] do
        File.write!(Lock.path(root), json)
        assert {:error, problems} = Lock.read(root)
        assert Enum.any?(problems, &(&1 =~ expected)), "#{json}: #{inspect(problems)}"
      end
    end
  end

  describe "declared/1" do
    test "indexes every journey by id with its IR and hash" do
      assert {:ok, declared} = Lock.declared([AshJourneys.Test.Offboarding])
      assert Map.keys(declared) |> Enum.sort() == ["remove_a_person", @journey]

      assert declared[@journey].hash ==
               AshJourneys.Info.hash(AshJourneys.Test.Offboarding, :revoke_a_leavers_access)
    end

    test "refuses a module that declares no journeys, and an id declared twice" do
      assert {:error, ["String does not use AshJourneys.Journeys"]} = Lock.declared([String])

      assert {:error, problems} =
               Lock.declared([AshJourneys.Test.Offboarding, AshJourneys.Test.Offboarding])

      assert Enum.sort(problems) == [
               "journey remove_a_person is declared by AshJourneys.Test.Offboarding and AshJourneys.Test.Offboarding",
               "journey revoke_a_leavers_access is declared by AshJourneys.Test.Offboarding and AshJourneys.Test.Offboarding"
             ]
    end
  end
end
