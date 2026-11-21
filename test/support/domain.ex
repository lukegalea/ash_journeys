defmodule AshJourneys.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshJourneys.Test.Member
  end
end
