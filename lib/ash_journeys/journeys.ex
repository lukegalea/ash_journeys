defmodule AshJourneys.Journeys do
  @moduledoc """
  Declares journeys in a module:

      defmodule MyApp.Journeys.Offboarding do
        use AshJourneys.Journeys,
          surfaces: MyApp.Journeys.Surfaces,
          personas: MyApp.Journeys.Personas,
          world: MyApp.Journeys.World

        journey :revoke_a_leavers_access do
          version 1
          kind :how_to
          title "Revoke a leaver's access"
          goal "Their sign-in stops working."
          outcome "Their access is revoked."
          locales [:en, :fr]

          persona :admin, :tenant_admin
          world packs: [:offboarding], bind: [leaver: {:user, :leaver}]

          step :find_the_person, as: :admin do
            open :users
            say "Open %{surface} and find the person who is leaving.", surface: ui(:users)
          end
        end
      end

  The options name the host modules the journeys are verified and run against:

    * `surfaces` implements `AshJourneys.SurfaceRegistry`; surface ids are checked
      against it;
    * `personas` implements `AshJourneys.Persona`;
    * `world` implements `AshJourneys.World`;
    * `gettext` is the host's `Gettext.Backend`. Narration and titles are msgids in
      its `journeys` domain (`mix ash_journeys.gettext.extract`), and labels from
      `ui/1` come from the same backend's `ash_a2ui` and `a2ui_metadata` domains.
      Without it a journey is rendered in the language it is written in.

  `AshJourneys.Dsl` describes the DSL and `AshJourneys.Info` reads it.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [AshJourneys.Dsl]],
    opt_schema: [
      surfaces: [
        type: :atom,
        required: true,
        doc: "The host's `AshJourneys.SurfaceRegistry`."
      ],
      personas: [type: :atom, required: true, doc: "The host's `AshJourneys.Persona`."],
      world: [type: :atom, required: true, doc: "The host's `AshJourneys.World`."],
      gettext: [type: :atom, doc: "The host's `Gettext.Backend`."]
    ]

  @impl Spark.Dsl
  def handle_opts(opts) do
    quote bind_quoted: [
            surfaces: opts[:surfaces],
            personas: opts[:personas],
            world: opts[:world],
            gettext: opts[:gettext]
          ] do
      @persist {:surfaces, surfaces}
      @persist {:personas, personas}
      @persist {:world, world}
      @persist {:gettext, gettext}
    end
  end
end
