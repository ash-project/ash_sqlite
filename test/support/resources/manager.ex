defmodule AshSqlite.Test.Manager do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("managers")
    repo(AshSqlite.TestRepo)
  end

  actions do
    default_accept(:*)
    defaults([:read, :update, :destroy])

    create :create do
      primary?(true)
      argument(:organization_id, :uuid, allow_nil?: false)

      change(manage_relationship(:organization_id, :organization, type: :append_and_remove))
    end
  end

  identities do
    identity(:uniq_code, :code)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:code, :string, allow_nil?: false, public?: true)
    attribute(:must_be_present, :string, allow_nil?: false, public?: true)
    attribute(:role, :string, public?: true)
  end

  relationships do
    belongs_to :organization, AshSqlite.Test.Organization do
      public?(true)
      attribute_writable?(true)
    end
  end
end
