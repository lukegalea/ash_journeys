defmodule AshJourneys.DeclaredTest do
  @moduledoc "`AshJourneys.Lock.declared/0`: the journeys the host configures."

  # The configured journeys are application env, which these tests set.
  use ExUnit.Case, async: false

  alias AshJourneys.Lock

  setup do
    previous = Application.fetch_env(:ash_journeys, :journeys)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_journeys, :journeys, value)
        :error -> Application.delete_env(:ash_journeys, :journeys)
      end
    end)
  end

  test "the configured modules' journeys, as declared/1 gives them" do
    Application.put_env(:ash_journeys, :journeys, [AshJourneys.Test.Offboarding])

    assert Lock.declared() == Lock.declared([AshJourneys.Test.Offboarding])

    assert {:ok, %{"revoke_a_leavers_access" => %{module: AshJourneys.Test.Offboarding}}} =
             Lock.declared()
  end

  test "no configuration declares nothing, and a module that declares no journeys is refused" do
    Application.delete_env(:ash_journeys, :journeys)
    assert Lock.declared() == {:ok, %{}}

    Application.put_env(:ash_journeys, :journeys, [String])
    assert Lock.declared() == {:error, ["String does not use AshJourneys.Journeys"]}
  end
end
