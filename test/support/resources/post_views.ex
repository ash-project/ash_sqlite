defmodule AshSqlite.Test.PostView do
  @moduledoc false
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read])
  end

  attributes do
    create_timestamp(:time)
    attribute(:browser, :atom, constraints: [one_of: [:firefox, :chrome, :edge]], public?: true)
  end

  relationships do
    belongs_to :post, AshSqlite.Test.Post do
      public?(true)
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
