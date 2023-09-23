defmodule AshSqlite.Test.Profile do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("profile")
    schema("profiles")
    repo(AshSqlite.TestRepo)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:description, :string)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  relationships do
    belongs_to(:author, AshSqlite.Test.Author)
  end
end
