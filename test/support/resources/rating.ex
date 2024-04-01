defmodule AshSqlite.Test.Rating do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    polymorphic?(true)
    repo AshSqlite.TestRepo
  end

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:score, :integer, public?: true)
    attribute(:resource_id, :uuid, public?: true)
  end
end
