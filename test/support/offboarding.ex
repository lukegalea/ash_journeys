defmodule AshJourneys.Test.Offboarding do
  @moduledoc "Fixture: every construct of the DSL, in journeys that verify cleanly."

  use AshJourneys.Journeys,
    surfaces: AshJourneys.Test.Surfaces,
    personas: AshJourneys.Test.Personas,
    world: AshJourneys.Test.World,
    gettext: AshJourneys.Test.Gettext

  journey :revoke_a_leavers_access do
    version 1
    kind :how_to
    title "Revoke a leaver's access"
    goal "Their sign-in stops working."
    outcome "Their access is revoked."
    locales [:en, :fr]
    metadata controls: ["C-1", "C-2"], owner: :people_team

    persona :admin, :tenant_admin
    persona :leaver, :member

    world packs: [:offboarding],
          bind: [admin: {:user, :admin}, leaver: {:user, "leaver@example.com"}],
          clock: ~U[2026-03-02 09:00:00Z],
          timestamps: [admin: [created_on: {0, :minute}], leaver: [created_on: {30, :minute}]]

    step :leaver_is_signed_in, as: :leaver do
      open :home
      say "The person who is leaving is still signed in."
    end

    step :find_the_person, as: :admin do
      open :people
      say "Open %{surface} and find the person who is leaving.", surface: ui(:people)

      figure :people,
        frame: {:table, "people"},
        highlight: {:row, :leaver},
        mask: [{:as_of, width: "6rem"}]
    end

    step :deactivate, as: :admin do
      row_action "people.deactivate", on: :leaver
      say "Choose %{action}.", action: ui({:row_action, "people.deactivate"})
      note :warning, "The next thing they do in the app sends them to sign in."

      expect trace: [:handle_event, {:ash_action, :deactivate}],
             one_correlation: true,
             audit: true

      expect record: {:leaver, lifecycle_status: :inactive}
      figure :deactivated, frame: {:row, :leaver}
    end

    step :their_session_is_dead, as: :leaver do
      open :home
      expect lands_on: :sign_in
      say "If they try the app again, they are sent to sign in."
    end
  end

  journey :remove_a_person do
    version 1
    kind :tutorial
    title "Remove a person"
    goal "They are gone."
    outcome "They no longer appear."
    locales [:en]

    persona :admin, :tenant_admin
    world bind: [leaver: {:user, :leaver}]

    step :remove, as: :admin do
      open :people
      row_action "people.remove", on: :leaver, confirm: true
      figure :confirm, frame: :dialog
      say "Choose %{action} and confirm.", action: ui({:row_action, "people.remove"})
      expect trace: [:handle_event, {:ash_action, :remove}]
    end
  end
end
