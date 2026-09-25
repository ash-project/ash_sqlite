# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregateScopeTest do
  use AshSqlite.RepoCase, async: false
  require Ash.Query

  defmodule ScopeFromContext do
    use Ash.Resource.Preparation

    @impl true
    def prepare(query, _opts, _context) do
      Ash.Query.do_filter(query, title: query.context[:visible_title] || "missing-context")
    end
  end

  defmodule Comment do
    use Ash.Resource, domain: AshSqlite.AggregateScopeTest.Domain, data_layer: AshSqlite.DataLayer

    sqlite do
      table("comments")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:post_id, :uuid)
      attribute(:title, :string)
      attribute(:likes, :integer)
    end

    actions do
      defaults([:read])

      read :visible do
        filter(expr(title == "visible"))
      end

      read :by_title do
        argument(:title, :string, allow_nil?: false)
        filter(expr(title == ^arg(:title)))
      end

      read :from_context do
        prepare(ScopeFromContext)
      end
    end
  end

  defmodule Post do
    use Ash.Resource, domain: AshSqlite.AggregateScopeTest.Domain, data_layer: AshSqlite.DataLayer

    sqlite do
      table("posts")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many :top, Comment do
        destination_attribute(:post_id)
        read_action(:visible)
        sort(likes: :desc)
        limit(2)
      end
    end

    aggregates do
      list(:top_likes, :top, :likes)

      first :least_top_likes, :top, :likes do
        sort(likes: :asc)
      end

      count(:top_count, :top)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Post)
      resource(Comment)
    end
  end

  setup do
    post = Ash.Seed.seed!(%AshSqlite.Test.Post{title: "endpoint review"})

    for {title, likes} <- [{"hidden", 10}, {"visible", 9}, {"visible", 8}] do
      Ash.Seed.seed!(%AshSqlite.Test.Comment{post_id: post.id, title: title, likes: likes})
    end

    %{query: Post |> Ash.Query.filter(id == ^post.id)}
  end

  test "list preserves endpoint action scope before relationship limit", %{query: query} do
    assert %{top: [%{likes: 9}, %{likes: 8}]} = query |> Ash.Query.load(:top) |> Ash.read_one!()
    assert %{top_likes: [9, 8]} = query |> Ash.Query.load(:top_likes) |> Ash.read_one!()
  end

  test "first preserves endpoint action scope before relationship limit", %{query: query} do
    assert %{least_top_likes: 8} = query |> Ash.Query.load(:least_top_likes) |> Ash.read_one!()
  end

  test "scalar endpoint action scope before relationship limit", %{query: query} do
    assert %{top_count: 2} = query |> Ash.Query.load(:top_count) |> Ash.read_one!()
  end

  test "a prepared aggregate query retains its action and arguments", %{query: query} do
    aggregate_query = Ash.Query.for_read(Comment, :by_title, %{title: "visible"})

    assert %{aggregates: %{visible_count: 2}} =
             query
             |> Ash.Query.aggregate(:visible_count, :count, :top, query: aggregate_query)
             |> Ash.read_one!()
  end

  test "a prepared aggregate query retains its preparation context", %{query: query} do
    aggregate_query =
      Comment
      |> Ash.Query.set_context(%{visible_title: "visible"})
      |> Ash.Query.for_read(:from_context)

    assert %{aggregates: %{visible_count: 2}} =
             query
             |> Ash.Query.aggregate(:visible_count, :count, :top, query: aggregate_query)
             |> Ash.read_one!()
  end
end
