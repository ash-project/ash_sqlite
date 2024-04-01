defmodule AshSqlite.Test.Profile do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("profile")
    repo(AshSqlite.TestRepo)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:description, :string, public?: true)
  end

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])
  end

  relationships do
    belongs_to(:author, AshSqlite.Test.Author, public?: true)
  end
end
