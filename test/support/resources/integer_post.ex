defmodule AshSqlite.Test.IntegerPost do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "integer_posts"
    repo AshSqlite.TestRepo
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    integer_primary_key(:id)
    attribute(:title, :string)
  end
end
