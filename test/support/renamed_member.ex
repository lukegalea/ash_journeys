defmodule AshJourneys.Test.RenamedMember do
  @moduledoc """
  Fixture: `AshJourneys.Test.Member`'s surface after a rename: the same table and
  row actions, titled "Staff", with deactivate labelled "Suspend". A journey
  approved against `Member` resolves other text on it.
  """

  use Ash.Resource,
    domain: AshJourneys.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2ui]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true, allow_nil?: false

    attribute :lifecycle_status, :atom,
      public?: true,
      constraints: [one_of: [:active, :inactive]],
      default: :active

    create_timestamp :created_on, public?: true
  end

  actions do
    defaults [:read, create: [:email]]

    update :deactivate do
      accept []
      change set_attribute(:lifecycle_status, :inactive)
    end

    update :activate do
      accept []
      change set_attribute(:lifecycle_status, :active)
    end

    destroy :remove
  end

  a2ui do
    surface_id "people"
    title "Staff"

    component :table, :people do
      fields [:email, :lifecycle_status, :created_on]
      row_actions [:deactivate, :activate, :remove]
    end

    action :deactivate do
      label "Suspend"
      visible_when lifecycle_status: :active
    end

    action :activate do
      visible_when lifecycle_status: :inactive
    end
  end
end
