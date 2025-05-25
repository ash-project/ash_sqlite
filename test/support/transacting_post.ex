defmodule AshSqlite.Test.TransactingPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("transacting_posts")
    repo AshSqlite.TransactingRepo
  end

  actions do
    defaults([:read, :destroy, update: :*, create: :*])
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:title, :string, public?: true)
    attribute(:subtitle, :string, public?: true)
  end
end
