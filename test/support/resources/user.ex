defmodule AshSqlite.Test.User do
  @moduledoc false
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:is_active, :boolean, public?: true)
  end

  sqlite do
    table "users"
    repo(AshSqlite.TestRepo)
  end

  relationships do
    belongs_to(:organization, AshSqlite.Test.Organization, public?: true)
    has_many(:accounts, AshSqlite.Test.Account, public?: true)
  end
end
