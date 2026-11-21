defmodule AshJourneys.PreflightTest do
  @moduledoc """
  The start-of-run check: whether a row action asks for confirmation depends on the
  catalog the surface renders with, so a dialog frame is checked here.
  """

  use ExUnit.Case, async: true

  import Spark.Test
  import AshJourneys.Test.JourneySource

  alias AshJourneys.Preflight
  alias AshJourneys.Test.Offboarding

  test "a journey whose declared confirmations match its surfaces passes" do
    assert Preflight.check(Offboarding, :revoke_a_leavers_access, catalog: :admin_v1) == :ok
    assert Preflight.check(Offboarding, :remove_a_person, catalog: :admin_v1) == :ok
  end

  test "a dialog frame on a step whose action asks for no confirmation is rejected" do
    # The basic catalog removes without asking.
    assert {:error, errors} = Preflight.check(Offboarding, :remove_a_person, catalog: :basic)

    assert ("step :remove: figure :confirm frames a dialog, but no row action before it asks " <>
              "for confirmation on this surface") in errors

    assert ~s(step :remove: row action "people.remove" is declared confirm: true, but asks for no confirmation) in errors
  end

  test "an action that asks for confirmation must be declared to" do
    module = fresh(__MODULE__)

    steps = """
    step :remove, as: :admin do
      open :people
      row_action "people.remove", on: :leaver
      say "Remove them."
    end
    """

    assert [] = dsl_errors(do: compile(module(module, journey(steps))))

    assert Preflight.check(module, :sample, catalog: :admin_v1) ==
             {:error,
              [
                ~S|step :remove: row action "people.remove" asks for confirmation (destructive); declare it confirm: true|
              ]}

    assert Preflight.check(module, :sample, catalog: :basic) == :ok
  end
end
