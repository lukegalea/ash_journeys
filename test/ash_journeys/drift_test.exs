defmodule AshJourneys.DriftTest do
  # The surface is swapped through the application environment, so these tests
  # run alone.
  use ExUnit.Case, async: false

  alias AshJourneys.{Approval, Export, Lock}
  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"

  setup context do
    root = Runs.root(context)
    declared = Runs.declared()

    for {id, locale} <- [{@journey, "en"}, {@journey, "fr"}, {"remove_a_person", "en"}],
        do: Runs.write!(root, declared, "r1", id, locale)

    assert {:ok, _} = Approval.approve(root, "r1", declared)
    on_exit(fn -> Application.delete_env(:ash_journeys, :people_ui) end)
    %{root: root, declared: declared}
  end

  defp rename!, do: Application.put_env(:ash_journeys, :people_ui, AshJourneys.Test.RenamedMember)

  test "a label renamed after approval fails the lock check", %{root: root, declared: declared} do
    {:ok, lock} = Lock.read(root)
    rename!()

    status = Lock.check(root, lock, declared)
    # remove_a_person names only the remove action, which kept its label.
    assert status.current == [{"remove_a_person", "en"}]
    assert [{@journey, "en", en}, {@journey, "fr", _fr}] = status.drifted

    assert ~s(text find_the_person.ui.surface was "People" in the run, and is now "Staff"; run it again) in en

    assert ~s(text deactivate.ui.action was "Deactivate" in the run, and is now "Suspend"; run it again) in en

    assert ~s(text deactivate.narration.1 was "Choose Deactivate." in the run, and is now "Choose Suspend."; run it again) in en

    assert Lock.check(root, lock, declared, texts: false).drifted == []
  end

  test "a label renamed after approval is never exported beside the old figures", %{
    root: root,
    declared: declared
  } do
    rename!()

    assert {:error, problems} = Export.pages(root, declared)
    assert Enum.any?(problems, &(&1 =~ ~r/^revoke_a_leavers_access \(en\): text .* "Staff"/))
    assert Enum.any?(problems, &(&1 =~ ~r/^revoke_a_leavers_access \(fr\): text /))
  end

  test "a run that recorded other text than the journey resolves to now is not approved", %{
    root: root,
    declared: declared
  } do
    Runs.write!(root, declared, "r2", @journey, "en",
      edit: &%{&1 | texts: Map.put(&1.texts, "title", "Another title")}
    )

    assert {:error, [problem]} = Approval.approve(root, "r2", declared)

    assert problem ==
             ~s(#{@journey}/en: text title was "Another title" in the run, and is now "Revoke a leaver's access"; run it again)
  end

  test "a re-shot run that resolved its text differently replaces the approved one", %{
    root: root,
    declared: declared
  } do
    rename!()

    for {id, locale} <- [{@journey, "en"}, {@journey, "fr"}, {"remove_a_person", "en"}],
        do: Runs.write!(root, declared, "r2", id, locale)

    assert {:ok, report} = Approval.approve(root, "r2", declared)

    assert %{outcome: :approved} =
             Enum.find(report.results, &(&1.journey == @journey and &1.locale == "en"))

    assert %{outcome: :kept} = Enum.find(report.results, &(&1.journey == "remove_a_person"))

    {:ok, lock} = Lock.read(root)
    assert Lock.check(root, lock, declared).current |> length() == 3
  end

  describe "the tasks" do
    setup %{root: root} do
      Application.put_env(:ash_journeys, :journeys, [AshJourneys.Test.Offboarding])
      Mix.shell(Mix.Shell.Process)
      cwd = File.cwd!()
      File.cd!(root)

      on_exit(fn ->
        File.cd!(cwd)
        Mix.shell(Mix.Shell.IO)
        Application.delete_env(:ash_journeys, :journeys)
      end)
    end

    test "lock --check and export both refuse a renamed label" do
      rename!()

      assert_raise Mix.Error, ~r/2 journey\(s\) are not proven by their approved run/, fn ->
        Mix.Task.rerun("ash_journeys.lock", ["--check"])
      end

      assert_raise Mix.Error, ~r/nothing was exported/, fn ->
        Mix.Task.rerun("ash_journeys.export", [])
      end

      refute File.exists?("docs/journeys")
    end
  end
end
