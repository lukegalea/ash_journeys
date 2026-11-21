defmodule AshJourneys.InfoTest do
  @moduledoc "Reading a journeys module back: its journeys, host modules and entities."

  use ExUnit.Case, async: true

  alias AshJourneys.Dsl.{Expect, Figure, Note, Open, RowAction, Say, World}
  alias AshJourneys.{Info, Ui}
  alias AshJourneys.Test.Offboarding

  test "lists the module's journeys and finds one by name" do
    assert Enum.map(Info.journeys(Offboarding), & &1.name) == [
             :revoke_a_leavers_access,
             :remove_a_person
           ]

    assert %{name: :remove_a_person, kind: :tutorial} =
             Info.journey(Offboarding, :remove_a_person)

    assert Info.journey(Offboarding, :missing) == nil

    assert_raise ArgumentError, ~r/declares no journey :missing/, fn ->
      Info.journey!(Offboarding, :missing)
    end
  end

  test "names the host modules" do
    assert Info.surface_registry(Offboarding) == AshJourneys.Test.Surfaces
    assert Info.persona_module(Offboarding) == AshJourneys.Test.Personas
    assert Info.world_module(Offboarding) == AshJourneys.Test.World
  end

  test "reads a journey's header, personas and world" do
    journey = Info.journey!(Offboarding, :revoke_a_leavers_access)

    assert %{version: 1, kind: :how_to, locales: [:en, :fr]} = journey
    assert journey.metadata == [controls: ["C-1", "C-2"], owner: :people_team]

    assert Enum.map(journey.personas, &{&1.name, &1.role}) == [
             admin: :tenant_admin,
             leaver: :member
           ]

    assert %World{packs: [:offboarding], clock: ~U[2026-03-02 09:00:00Z]} = journey.world
    assert journey.world.timestamps[:leaver] == [created_on: {30, :minute}]
  end

  test "keeps a step's body in declaration order, and its narration apart" do
    journey = Info.journey!(Offboarding, :revoke_a_leavers_access)
    deactivate = Enum.find(journey.steps, &(&1.name == :deactivate))

    assert deactivate.as == :admin

    assert [
             %RowAction{id: "people.deactivate", on: :leaver, confirm: false},
             %Expect{
               trace: [:handle_event, {:ash_action, :deactivate}],
               one_correlation: true,
               audit: true
             },
             %Expect{record: {:leaver, [lifecycle_status: :inactive]}},
             %Figure{name: :deactivated, frame: {:row, :leaver}}
           ] = deactivate.body

    assert [
             %Say{bindings: [action: %Ui{target: {:row_action, "people.deactivate"}}]},
             %Note{kind: :warning}
           ] = deactivate.narration

    find = Enum.find(journey.steps, &(&1.name == :find_the_person))

    assert [
             %Open{surface: :people},
             %Figure{
               frame: {:table, "people"},
               highlight: {:row, :leaver},
               mask: [{:as_of, [width: "6rem"]}]
             }
           ] = find.body
  end

  test "ui/1 refuses a target that is neither a surface nor a row action" do
    assert_raise ArgumentError, ~r/ui\/1 takes a surface id/, fn -> Ui.ui({:table, "people"}) end
  end
end
