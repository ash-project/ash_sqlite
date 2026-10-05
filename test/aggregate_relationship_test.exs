# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregateRelationshipTest do
  use AshSqlite.RepoCase, async: false
  require Ash.Query

  defmodule Comment do
    use Ash.Resource,
      domain: AshSqlite.AggregateRelationshipTest.Domain,
      data_layer: AshSqlite.DataLayer

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
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: AshSqlite.AggregateRelationshipTest.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("posts")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:author_id, :uuid)
      attribute(:title, :string)
      attribute(:category, :string)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many(:comments, Comment, destination_attribute: :post_id)

      has_many :top_comments, Comment do
        destination_attribute(:post_id)
        sort(likes: :desc)
        limit(2)
      end

      has_many(:links, AshSqlite.AggregateRelationshipTest.TenantLink,
        destination_attribute: :source_post_id
      )

      many_to_many :linked_posts, __MODULE__ do
        through(AshSqlite.AggregateRelationshipTest.TenantLink)
        join_relationship(:links)
        source_attribute_on_join_resource(:source_post_id)
        destination_attribute_on_join_resource(:destination_post_id)
      end
    end

    aggregates do
      count :top_count_matching, :top_comments do
        filter(expr(likes == 1))
      end

      first :top_first_matching, :top_comments, :likes do
        filter(expr(likes == 1))
      end

      list :top_list_matching, :top_comments, :likes do
        filter(expr(likes == 1))
      end
    end
  end

  defmodule TenantPost do
    use Ash.Resource,
      domain: AshSqlite.AggregateRelationshipTest.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("posts")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:author_id, :uuid)
      attribute(:title, :string)
      attribute(:category, :string)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:category)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many(:comments, Comment, destination_attribute: :post_id)
    end
  end

  defmodule TenantLink do
    use Ash.Resource,
      domain: AshSqlite.AggregateRelationshipTest.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("post_links")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      attribute(:source_post_id, :uuid, primary_key?: true, allow_nil?: false)
      attribute(:destination_post_id, :uuid, primary_key?: true, allow_nil?: false)
      attribute(:state, :string)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:state)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Author do
    use Ash.Resource,
      domain: AshSqlite.AggregateRelationshipTest.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("authors")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many(:tenant_posts, TenantPost, destination_attribute: :author_id)
    end

    aggregates do
      count(:tenant_post_count, :tenant_posts)
      count(:tenant_comment_count, [:tenant_posts, :comments])
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Author)
      resource(Post)
      resource(Comment)
      resource(TenantPost)
      resource(TenantLink)
    end
  end

  setup do
    author = Ash.Seed.seed!(%AshSqlite.Test.Author{first_name: "deeper", last_name: "review"})

    a =
      Ash.Seed.seed!(%AshSqlite.Test.Post{title: "alice", category: "acme", author_id: author.id})

    b =
      Ash.Seed.seed!(%AshSqlite.Test.Post{title: "bob", category: "other", author_id: author.id})

    for {post, likes} <- [{a, 1}, {b, 2}, {b, 3}] do
      Ash.Seed.seed!(%AshSqlite.Test.Comment{title: "comment", post_id: post.id, likes: likes})
    end

    %{author: author, a: a, b: b}
  end

  test "single-hop attribute tenant scope control", %{author: author} do
    assert [_] = TenantPost |> Ash.Query.set_tenant("acme") |> Ash.read!()

    assert %{tenant_post_count: 1} =
             Author
             |> Ash.Query.filter(id == ^author.id)
             |> Ash.Query.load(:tenant_post_count)
             |> Ash.read_one!(tenant: "acme")
  end

  test "intermediate attribute tenancy scopes rows", %{author: author} do
    assert [_] = TenantPost |> Ash.Query.set_tenant("acme") |> Ash.read!()

    assert %{tenant_comment_count: 1} =
             Author
             |> Ash.Query.filter(id == ^author.id)
             |> Ash.Query.load(:tenant_comment_count)
             |> Ash.read_one!(tenant: "acme")
  end

  test "aggregate tenant bypass does not change a sibling's tenant scope", %{author: author} do
    result =
      Author
      |> Ash.Query.filter(id == ^author.id)
      |> Ash.Query.load(:tenant_post_count)
      |> Ash.Query.aggregate(:all_count, :count, :tenant_posts, multitenancy: :bypass)
      |> Ash.read_one!(tenant: "acme")

    assert result.tenant_post_count == 1
    assert result.aggregates.all_count == 2
  end

  test "aggregate tenant bypass includes intermediate resources", %{author: author} do
    result =
      Author
      |> Ash.Query.filter(id == ^author.id)
      |> Ash.Query.load(:tenant_comment_count)
      |> Ash.Query.aggregate(:all_count, :count, [:tenant_posts, :comments],
        multitenancy: :bypass
      )
      |> Ash.read_one!(tenant: "acme")

    assert result.tenant_comment_count == 1
    assert result.aggregates.all_count == 3
  end

  test "aggregate tenant bypass includes through resources", %{a: source} do
    for state <- [:active, :archived] do
      target = Ash.Seed.seed!(%AshSqlite.Test.Post{title: to_string(state)})

      Ash.Seed.seed!(%AshSqlite.Test.PostLink{
        source_post_id: source.id,
        destination_post_id: target.id,
        state: state
      })
    end

    result =
      Post
      |> Ash.Query.filter(id == ^source.id)
      |> Ash.Query.aggregate(:scoped_count, :count, :linked_posts)
      |> Ash.Query.aggregate(:all_count, :count, :linked_posts, multitenancy: :bypass)
      |> Ash.read_one!(tenant: "active")

    assert result.aggregates.scoped_count == 1
    assert result.aggregates.all_count == 2
  end

  test "many-to-many through attribute tenancy scopes rows", %{a: a} do
    for state <- [:active, :archived] do
      target = Ash.Seed.seed!(%AshSqlite.Test.Post{title: to_string(state)})

      Ash.Seed.seed!(%AshSqlite.Test.PostLink{
        source_post_id: a.id,
        destination_post_id: target.id,
        state: state
      })
    end

    assert [_] = TenantLink |> Ash.Query.set_tenant("active") |> Ash.read!()

    assert %{aggregates: %{visible_count: 1}} =
             Post
             |> Ash.Query.filter(id == ^a.id)
             |> Ash.Query.aggregate(:visible_count, :count, :linked_posts)
             |> Ash.read_one!(tenant: "active")
  end

  test "limited relationship scalar filter control", %{b: b} do
    assert %{top_count_matching: 0} =
             Post
             |> Ash.Query.filter(id == ^b.id)
             |> Ash.Query.load(:top_count_matching)
             |> Ash.read_one!()
  end

  test "limited relationship first filter runs after limit", %{a: a} do
    for likes <- [4, 5] do
      Ash.Seed.seed!(%AshSqlite.Test.Comment{title: "top", post_id: a.id, likes: likes})
    end

    query = Post |> Ash.Query.filter(id == ^a.id)

    assert %{top_comments: [%{likes: 5}, %{likes: 4}]} =
             query |> Ash.Query.load(:top_comments) |> Ash.read_one!()

    assert %{top_count_matching: 0} =
             query |> Ash.Query.load(:top_count_matching) |> Ash.read_one!()

    assert %{top_first_matching: nil} =
             query |> Ash.Query.load(:top_first_matching) |> Ash.read_one!()
  end

  test "limited relationship list filter runs after limit", %{a: a} do
    for likes <- [4, 5] do
      Ash.Seed.seed!(%AshSqlite.Test.Comment{title: "top", post_id: a.id, likes: likes})
    end

    assert %{top_list_matching: []} =
             Post
             |> Ash.Query.filter(id == ^a.id)
             |> Ash.Query.load(:top_list_matching)
             |> Ash.read_one!()
  end
end
