defmodule AshJourneys.Test.Gettext do
  @moduledoc false
  # A real Gettext backend with a partial French catalog: the journeys' narration,
  # and the labels (`a2ui_metadata`) of the people surface.
  use Gettext.Backend, otp_app: :ash_journeys, priv: "test/support/gettext"
end
