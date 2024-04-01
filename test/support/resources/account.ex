defmodule AshSqlite.Test.Account do
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

  calculations do
    calculate(
      :active,
      :boolean,
      expr(is_active),
      public?: true
    )
  end

  sqlite do
    table "accounts"
    repo(AshSqlite.TestRepo)
  end

  relationships do
    belongs_to(:user, AshSqlite.Test.User, public?: true)
  end
end
