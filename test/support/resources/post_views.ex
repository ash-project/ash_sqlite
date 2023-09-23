defmodule AshSqlite.Test.PostView do
  @moduledoc false
  use Ash.Resource, data_layer: AshSqlite.DataLayer

  actions do
    defaults([:create, :read])
  end

  attributes do
    create_timestamp(:time)
    attribute(:browser, :atom, constraints: [one_of: [:firefox, :chrome, :edge]])
  end

  relationships do
    belongs_to :post, AshSqlite.Test.Post do
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  resource do
    require_primary_key?(false)
  end

  sqlite do
    table "post_views"
    repo AshSqlite.TestRepo

    references do
      reference :post, ignore?: true
    end
  end
end
