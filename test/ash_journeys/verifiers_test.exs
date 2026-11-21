defmodule AshJourneys.VerifiersTest do
  @moduledoc """
  Every verifier rule, each with a journey that breaks it and the line its error
  points at. Errors are collected with `Spark.Test` rather than printed.
  """

  use ExUnit.Case, async: true

  import Spark.Test
  import AshJourneys.Test.JourneySource

  @valid_step """
  step :find, as: :admin do
    open :people
    say "Open %{surface}.", surface: ui(:people)
  end
  """

  # Compiles one journey with `steps` and returns {source, errors}.
  defp verify(steps, opts \\ []) do
    module = fresh(__MODULE__)
    source = module(module, journey(steps, opts), opts)

    errors =
      case dsl_errors(do: compile(source)) do
        [{^module, errors}] -> errors
        [] -> []
      end

    {source, errors}
  end

  # Asserts exactly one error, matching `pattern`, located at the line holding `marker`.
  defp assert_located(steps, pattern, marker, opts \\ []) do
    {source, errors} = verify(steps, opts)
    assert [%Spark.Error.DslError{message: message, location: location}] = errors
    assert message =~ pattern
    assert location, "the error carries no location"
    assert :erl_anno.line(location) == line_of(source, marker)
    message
  end

  test "a journey that keeps every rule verifies cleanly" do
    assert {_source, []} = verify(@valid_step)
  end

  describe "the journey on its own terms" do
    test "a step taken as an undeclared persona" do
      steps = """
      step :find, as: :auditor do
        open :people
        say "Open the list."
      end
      """

      message = assert_located(steps, "is taken as :auditor", "step :find")
      assert message =~ "[:admin, :leaver]"
    end

    test "a step with no narration" do
      steps = """
      step :silent, as: :admin do
        open :people
        note :tip, "A note is an aside, not narration."
      end
      """

      assert_located(steps, "step :silent has no narration", "step :silent")
    end

    test "two steps with one name" do
      steps = @valid_step <> String.replace(@valid_step, "as: :admin do", "as: :admin do # again")
      assert_located(steps, "step :find is declared more than once", "# again")
    end

    test "two personas with one name" do
      header = """
      version 1
      kind :how_to
      title "T"
      goal "G"
      outcome "O"
      locales [:en]
      persona :admin, :tenant_admin
      persona :admin, :member # again
      """

      assert_located(@valid_step, "persona :admin is declared more than once", "# again",
        header: header
      )
    end

    test "two journeys with one name" do
      module = fresh(__MODULE__)
      source = module(module, journey(@valid_step) <> journey(@valid_step))
      assert [{^module, [error]}] = dsl_errors(do: compile(source))
      assert error.message =~ "journey :sample is declared more than once"
    end

    test "a mask without a size" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        figure :people, mask: [:as_of]
      end
      """

      message = assert_located(steps, "masks :as_of without a fixed-width box", "figure :people")
      assert message =~ ~s({:as_of, width: "6rem"})
    end

    test "a mask whose width is not a length" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        figure :people, mask: [{:as_of, width: "wide"}]
      end
      """

      assert_located(steps, "without a fixed-width box", "figure :people")
    end

    test "a mask with an option other than width" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        figure :people, mask: [{:as_of, width: "6rem", colour: "red"}]
      end
      """

      assert_located(steps, "takes only `width`", "figure :people")
    end

    test "a dialog frame with no confirmed row action before it" do
      steps = """
      step :remove, as: :admin do
        open :people
        figure :confirm, frame: :dialog
        row_action "people.remove", on: :leaver
        say "Remove them."
      end
      """

      assert_located(steps, "figure :confirm frames a dialog", "figure :confirm")
    end

    test "a placeholder with no binding, and a binding with no placeholder" do
      unbound = """
      step :find, as: :admin do
        open :people
        say "Open %{surface}."
      end
      """

      assert_located(unbound, "has no binding for %{surface}", "say ")

      unused = """
      step :find, as: :admin do
        open :people
        say "Open the list.", surface: ui(:people)
      end
      """

      assert_located(unused, "binds surface, which it never uses", "say ")
    end

    test "a placeholder bound to something other than ui/1" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Open %{surface}.", surface: "People"
      end
      """

      assert_located(steps, "bind it to ui/1", "say ")
    end

    test "a step naming a record the world does not bind" do
      steps = """
      step :deactivate, as: :admin do
        open :people
        row_action "people.deactivate", on: :ghost
        say "Deactivate them."
      end
      """

      assert_located(steps, ":ghost is not bound by the world", "row_action")
    end

    test "an expect that expects nothing, and an audit with no trace" do
      nothing = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        expect one_correlation: false
      end
      """

      assert_located(nothing, "expect expects nothing", "expect ")

      audit = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        expect audit: true
      end
      """

      assert_located(audit, "audit: true qualifies a trace", "expect ")
    end

    test "timestamps with no clock, and for a record the world does not bind" do
      header = """
      version 1
      kind :how_to
      title "T"
      goal "G"
      outcome "O"
      locales [:en]
      persona :admin, :tenant_admin
      world bind: [leaver: {:user, :leaver}], timestamps: [ghost: [created_on: {1, :hour}]]
      """

      {source, errors} = verify(@valid_step, header: header)
      messages = Enum.map(errors, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "pins :ghost, which `bind` does not bind"))
      assert Enum.any?(messages, &(&1 =~ "give the world a clock"))

      assert Enum.all?(errors, &(:erl_anno.line(&1.location) == line_of(source, "world bind")))
    end

    test "metadata that is not JSON data" do
      header = """
      version 1
      kind :how_to
      title "T"
      goal "G"
      outcome "O"
      locales [:en]
      metadata owner: {:team, 1}
      persona :admin, :tenant_admin
      """

      assert_located(@valid_step, "metadata must be JSON data", "journey :sample", header: header)
    end

    test "a journey with no locales" do
      header = """
      version 1
      kind :how_to
      title "T"
      goal "G"
      outcome "O"
      locales []
      persona :admin, :tenant_admin
      """

      assert_located(@valid_step, "names no locales", "journey :sample", header: header)
    end
  end

  describe "references to the application" do
    test "an unknown surface" do
      steps = """
      step :find, as: :admin do
        open :nowhere
        say "Open the list."
      end
      """

      assert_located(
        steps,
        ":nowhere is not a surface in AshJourneys.Test.Surfaces",
        "open :nowhere"
      )
    end

    test "an unknown surface to land on, and in ui/1" do
      landing = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        expect lands_on: :nowhere
      end
      """

      assert_located(landing, ":nowhere is not a surface", "expect ")

      label = """
      step :find, as: :admin do
        open :people
        say "Open %{surface}.", surface: ui(:nowhere)
      end
      """

      assert_located(label, ":nowhere is not a surface", "say ")
    end

    test "an unknown row-action id" do
      steps = """
      step :deactivate, as: :admin do
        open :people
        row_action "people.suspend", on: :leaver
        say "Suspend them."
      end
      """

      message =
        assert_located(
          steps,
          ~s(surface :people has no row action "people.suspend"),
          "row_action"
        )

      assert message =~ ~s("people.deactivate")
    end

    test "an unknown row-action id in ui/1" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Choose %{action}.", action: ui({:row_action, "people.suspend"})
      end
      """

      assert_located(steps, ~s(has no row action "people.suspend"), "say ")
    end

    test "a row action on a surface that is not an A2UI surface" do
      steps = """
      step :deactivate, as: :admin do
        open :home
        row_action "people.deactivate", on: :leaver
        say "Deactivate them."
      end
      """

      assert_located(steps, "surface :home is not an A2UI surface", "row_action")
    end

    test "a row action before the persona opens any surface" do
      steps = """
      step :deactivate, as: :admin do
        row_action "people.deactivate", on: :leaver
        say "Deactivate them."
      end
      """

      assert_located(steps, "its persona has no surface open", "row_action")
    end

    test "a row action on the surface another persona has open" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Open the list."
      end

      step :deactivate, as: :leaver do
        row_action "people.deactivate", on: :leaver
        say "Deactivate them."
      end
      """

      assert_located(steps, "its persona has no surface open", "row_action")
    end

    test "an unknown table" do
      steps = """
      step :find, as: :admin do
        open :people
        say "Open the list."
        figure :people, frame: {:table, "staff"}
      end
      """

      assert_located(steps, ~s(surface :people has no table "staff"), "figure :people")
    end

    test "an unknown Ash action in a trace" do
      steps = """
      step :deactivate, as: :admin do
        open :people
        row_action "people.deactivate", on: :leaver
        say "Deactivate them."
        expect trace: [:handle_event, {:ash_action, :suspend}]
      end
      """

      assert_located(
        steps,
        "trace names Ash action :suspend, which AshJourneys.Test.Member does not have",
        "expect "
      )
    end

    test "an Ash action in a trace with no resource to check it on" do
      steps = """
      step :home, as: :admin do
        open :home
        say "Go home."
        expect trace: [{:ash_action, :read}]
      end
      """

      assert_located(steps, "no resource to check it on", "expect ")
    end

    test "a host module that does not implement its behaviour" do
      module = fresh(__MODULE__)
      source = module(module, journey(@valid_step), surfaces: "AshJourneys.Test.Personas")
      assert [{^module, [error]}] = dsl_errors(do: compile(source))

      assert error.message =~
               "surfaces: AshJourneys.Test.Personas must be a module implementing AshJourneys.SurfaceRegistry"
    end
  end
end
