defmodule AshJourneys.IrTest do
  @moduledoc """
  The IR and its content hash: JSON data, RFC 8785 canonical, the same for the same
  declaration however it is spelled, and different for any change.
  """

  use ExUnit.Case, async: true

  import Spark.Test
  import AshJourneys.Test.JourneySource

  alias AshJourneys.{Info, Ir}
  alias AshJourneys.Test.Offboarding

  @journey """
  journey :sample do
    version 1
    kind :how_to
    title "Revoke access"
    goal "Their sign-in stops working."
    outcome "Their access is revoked."
    locales [:en, :fr]
    metadata controls: ["C-1"], owner: :people_team

    persona :admin, :tenant_admin
    persona :leaver, :member

    world packs: [:offboarding],
          bind: [admin: {:user, :admin}, leaver: {:user, :leaver}],
          clock: ~U[2026-03-02 09:00:00Z],
          timestamps: [admin: [created_on: {0, :minute}], leaver: [created_on: {30, :minute}]]

    step :find, as: :admin do
      open :people
      say "Open %{surface}.", surface: ui(:people)
      figure :people, frame: {:table, "people"}, highlight: {:row, :leaver}, mask: [{:as_of, width: "6rem"}, {:clock, width: "4rem"}]
    end

    step :deactivate, as: :admin do
      row_action "people.deactivate", on: :leaver
      say "Choose %{action}.", action: ui({:row_action, "people.deactivate"})
      note :warning, "They are sent to sign in."
      expect trace: [:handle_event, {:ash_action, :deactivate}], one_correlation: true, audit: true
      expect record: {:leaver, lifecycle_status: :inactive}
    end

    step :dead, as: :leaver do
      open :home
      expect lands_on: :sign_in
      say "They are sent to sign in."
    end
  end
  """

  # The same declaration, spelled differently: options, keyword entries and masks in
  # other orders, options moved into do-blocks, and a default written out.
  @respelled """
  journey :sample do
    metadata owner: :people_team, controls: ["C-1"]
    locales [:en, :fr]
    outcome "Their access is revoked."
    goal "Their sign-in stops working."
    title "Revoke access"
    kind :how_to
    version 1

    persona :admin, :tenant_admin
    persona :leaver, :member

    world timestamps: [leaver: [created_on: {30, :minute}], admin: [created_on: {0, :minute}]],
          clock: ~U[2026-03-02 09:00:00Z],
          bind: [leaver: {:user, :leaver}, admin: {:user, :admin}],
          packs: [:offboarding]

    step :find, as: :admin do
      open :people
      say "Open %{surface}.", surface: ui(:people)

      figure :people do
        mask [{:clock, width: "4rem"}, {:as_of, width: "6rem"}]
        highlight {:row, :leaver}
        frame {:table, "people"}
      end
    end

    step :deactivate, as: :admin do
      row_action "people.deactivate", confirm: false, on: :leaver
      say "Choose %{action}.", action: ui({:row_action, "people.deactivate"})
      note :warning, "They are sent to sign in."
      expect audit: true, one_correlation: true, trace: [:handle_event, {:ash_action, :deactivate}]
      expect record: {:leaver, lifecycle_status: :inactive}
    end

    step :dead, as: :leaver do
      open :home
      expect lands_on: :sign_in
      say "They are sent to sign in."
    end
  end
  """

  # Each is one change to `@journey`; each must change the hash.
  @changes [
    version: {"version 1", "version 2"},
    kind: {"kind :how_to", "kind :tutorial"},
    title: {~s(title "Revoke access"), ~s(title "Revoke someone's access")},
    narration: {~s(say "Open %{surface}."), ~s(say "Go to %{surface}.")},
    note: {"note :warning", "note :tip"},
    locales: {"locales [:en, :fr]", "locales [:en]"},
    metadata: {~s(controls: ["C-1"]), ~s(controls: ["C-2"])},
    persona_role: {"persona :leaver, :member", "persona :leaver, :guest"},
    pack: {"packs: [:offboarding]", "packs: [:offboarding, :extra]"},
    clock: {"~U[2026-03-02 09:00:00Z]", "~U[2026-03-02 10:00:00Z]"},
    offset: {"{30, :minute}", "{31, :minute}"},
    mask_width: {~s(width: "6rem"), ~s(width: "7rem")},
    highlight: {", highlight: {:row, :leaver}", ""},
    confirm: {"on: :leaver\n", "on: :leaver, confirm: true\n"},
    trace: {"[:handle_event, {:ash_action, :deactivate}]", "[{:ash_action, :deactivate}]"},
    one_correlation: {"one_correlation: true", "one_correlation: false"},
    record: {"lifecycle_status: :inactive", "lifecycle_status: :active"},
    lands_on: {"expect lands_on: :sign_in", "expect lands_on: :home"},
    step_name: {"step :dead", "step :gone"}
  ]

  defp hash_of(journey) do
    module = fresh(__MODULE__)
    assert [] = dsl_errors(do: compile(module(module, journey)))
    Info.hash(module, :sample)
  end

  test "the IR is JSON data" do
    ir = Info.ir(Offboarding, :revoke_a_leavers_access)
    assert ir |> Jason.encode!() |> Jason.decode!() == ir
  end

  test "the hash is the SHA-256 of the RFC 8785 canonical JSON of the IR" do
    ir = Info.ir(Offboarding, :revoke_a_leavers_access)
    json = Ir.canonical_json(ir)

    assert json == Jcs.encode(ir)
    assert String.starts_with?(json, ~s({"format":1,"goal":"Their sign-in stops working.","id":))
    refute json =~ ~r/[\n ]{2}/

    assert Info.hash(Offboarding, :revoke_a_leavers_access) ==
             :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end

  test "the hash is stable across compiles" do
    # Pinned: a change to this value is a change to every approved journey's hash.
    assert Info.hash(Offboarding, :revoke_a_leavers_access) ==
             "4b5c68a24f4163115c3c6042899f82d346df2419ed2e0aa3a8406ffc9f460ed4"

    assert hash_of(@journey) == hash_of(@journey)
  end

  test "the hash does not depend on how the declaration is spelled or where it lives" do
    assert hash_of(@respelled) == hash_of(@journey)
  end

  for {name, {from, to}} <- @changes do
    test "a change to the #{name} changes the hash" do
      {from, to} = {unquote(from), unquote(to)}
      assert @journey =~ from
      assert hash_of(String.replace(@journey, from, to, global: false)) != hash_of(@journey)
    end
  end

  test "a step's surface is the one its persona is on" do
    steps = Info.ir(Offboarding, :revoke_a_leavers_access)["steps"]

    assert Enum.map(steps, &{&1["name"], &1["as"], &1["surface"]}) == [
             {"leaver_is_signed_in", "leaver", "home"},
             {"find_the_person", "admin", "people"},
             {"deactivate", "admin", "people"},
             {"their_session_is_dead", "leaver", "home"}
           ]

    [_, _, deactivate, _] = steps

    assert %{"type" => "row_action", "id" => "people.deactivate", "surface" => "people"} =
             hd(deactivate["body"])

    assert %{"action" => %{"type" => "row_action", "surface" => "people"}} =
             hd(deactivate["narration"])["bindings"]
  end

  test "the world's offsets are seconds after its clock" do
    assert %{
             "clock" => "2026-03-02T09:00:00Z",
             "bind" => %{"leaver" => ["user", "leaver@example.com"]},
             "timestamps" => %{
               "admin" => %{"created_on" => 0},
               "leaver" => %{"created_on" => 1800}
             }
           } = Info.ir(Offboarding, :revoke_a_leavers_access)["world"]
  end
end
