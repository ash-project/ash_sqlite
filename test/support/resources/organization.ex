defmodule AshSqlite.Test.Organization do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("orgs")
    repo(AshSqlite.TestRepo)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:name, :string)
  end

  # relationships do
  #   has_many(:users, AshSqlite.Test.User)
  #   has_many(:posts, AshSqlite.Test.Post)
  #   has_many(:managers, AshSqlite.Test.Manager)
  # end
end
