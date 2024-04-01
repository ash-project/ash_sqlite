defmodule AshSqlite.Test.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer,
    authorizers: [
      Ash.Policy.Authorizer
    ]

  policies do
    bypass action_type(:read) do
      # Check that the comment is in the same org (via post) as actor
      authorize_if(relates_to_actor_via([:post, :organization, :users]))
    end
  end

  sqlite do
    table "comments"
    repo(AshSqlite.TestRepo)

    references do
      reference(:post, on_delete: :delete, on_update: :update, name: "special_name_fkey")
    end
  end

  actions do
    default_accept(:*)
    defaults([:read, :update, :destroy])

    create :create do
      primary?(true)
      argument(:rating, :map)

      change(manage_relationship(:rating, :ratings, on_missing: :ignore, on_match: :create))
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:likes, :integer, public?: true)
    attribute(:arbitrary_timestamp, :utc_datetime_usec, public?: true)
    create_timestamp(:created_at, writable?: true, public?: true)
  end

  relationships do
    belongs_to(:post, AshSqlite.Test.Post, public?: true)
    belongs_to(:author, AshSqlite.Test.Author, public?: true)

    has_many(:ratings, AshSqlite.Test.Rating,
      public?: true,
      destination_attribute: :resource_id,
      relationship_context: %{data_layer: %{table: "comment_ratings"}}
    )

    has_many(:popular_ratings, AshSqlite.Test.Rating,
      public?: true,
      destination_attribute: :resource_id,
      relationship_context: %{data_layer: %{table: "comment_ratings"}},
      filter: expr(score > 5)
    )
  end
end
