defmodule AshSqlite.Test.Account do
  @moduledoc false
  use Ash.Resource, data_layer: AshSqlite.DataLayer

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:is_active, :boolean)
  end

  calculations do
    calculate(
      :active,
      :boolean,
      expr(is_active)
    )
  end

  sqlite do
    table "accounts"
    repo(AshSqlite.TestRepo)
  end

  relationships do
    belongs_to(:user, AshSqlite.Test.User)
  end
end
