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

  describe "check/3" do
    test "an approved run of the current declaration is current; the rest is unapproved", %{
      root: root,
      declared: declared
    } do
      status = Lock.check(root, approved(root, declared), declared)

      assert status.current == [{@journey, "en"}]
      assert status.unapproved == [{"remove_a_person", "en"}, {@journey, "fr"}]
      assert status.stale == []
      assert status.altered == []
      assert status.drifted == []
      assert status.orphaned == []
    end

    test "a declaration that changed after its run was approved is stale", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      changed = put_in(declared, [@journey, :hash], String.duplicate("a", 64))

      assert %{stale: [{@journey, "en", [reason]}], current: []} =
               Lock.check(root, lock, changed)

      assert reason =~ "the declaration is aaaaaaaaaaaa"
    end

    test "editing the lock's hash to the new declaration does not make the old run current", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      new_hash = String.duplicate("a", 64)
      changed = put_in(declared, [@journey, :hash], new_hash)
      edited = put_in(lock.journeys[@journey]["en"].hash, new_hash)

      assert %{altered: [{@journey, "en", reasons}], current: []} =
               Lock.check(root, edited, changed)

      assert [reason] = reasons
      assert reason =~ ~s(the lock records hash "aaaa)
      assert reason =~ ~s(but its approved manifest has "#{declared[@journey].hash}")
    end

    test "a run from another build than the lock pins is stale", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      moved = %{lock | browser: %{name: "chromium", version: "999.0.0.0"}}

      assert %{stale: [{@journey, "en", [reason]}], current: []} =
               Lock.check(root, moved, declared)

      assert reason =~ "the lock pins chromium 999.0.0.0"
    end

    test "approved files that are gone or not the ones hashed are altered", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      dir = Lock.approved_dir(root, "en", @journey)
      File.write!(Path.join(dir, "find_the_person.people.png"), "not the figure")

      assert %{altered: [{@journey, "en", [reason]}]} = Lock.check(root, lock, declared)
      assert reason == "find_the_person.people.png is not the file the lock approved"

      File.rm_rf!(dir)
      assert %{altered: [{@journey, "en", reasons}]} = Lock.check(root, lock, declared)
      assert Enum.all?(reasons, &(&1 =~ "is missing from"))
    end

    test "a lock entry whose figures are not its manifest's is altered", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)

      edited =
        update_in(lock.journeys[@journey]["en"].figures["find_the_person.people"], fn figure ->
          %{figure | raster_sha256: String.duplicate("c", 64)}
        end)

      assert %{altered: [{@journey, "en", [reason]}]} = Lock.check(root, edited, declared)
      assert reason =~ "the lock records figures"
    end

    test "an approved manifest that would no longer be approved is altered", %{
      root: root,
      declared: declared
    } do
      # A retried run, approved by a hand edit: the manifest and the lock agree, and
      # the lock hashes the manifest, but approval would refuse it.
      lock = approved(root, declared)
      dir = Lock.approved_dir(root, "en", @journey)
      path = Path.join(dir, "manifest.json")
      {:ok, manifest} = AshJourneys.Manifest.read(path)
      AshJourneys.Manifest.write!(%{manifest | retries: 1}, dir)
      edited = put_in(lock.journeys[@journey]["en"].manifest_sha256, sha256(path))

      assert %{altered: [{@journey, "en", [reason]}]} = Lock.check(root, edited, declared)
      assert reason =~ "the approved run the run needed 1 retry"
    end

    test "an entry for a locale the journey no longer declares is orphaned", %{
      root: root,
      declared: declared
    } do
      lock = approved(root, declared)
      fewer = put_in(declared, [@journey, :ir, "locales"], ["fr"])

      assert %{orphaned: [{@journey, "en"}], stale: [], unapproved: [{@journey, "fr"}]} =
               Lock.check(root, lock, Map.take(fewer, [@journey]))
    end
  end

  defp sha256(path), do: AshJourneys.Json.sha256(File.read!(path))

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
