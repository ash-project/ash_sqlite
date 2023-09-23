defmodule AshSqlite.Test.User do
  @moduledoc false
  use Ash.Resource, data_layer: AshSqlite.DataLayer

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:is_active, :boolean)
  end

  sqlite do
    table "users"
    repo(AshSqlite.TestRepo)
  end

  relationships do
    belongs_to(:organization, AshSqlite.Test.Organization)
    has_many(:accounts, AshSqlite.Test.Account)
  end
end
