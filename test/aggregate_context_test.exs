# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregateContextTest do
  use AshSqlite.RepoCase, async: false

  require Ash.Query

  defmodule ContextFilter do
    use Ash.Resource.Preparation

    @impl true
    def prepare(query, opts, context) do
      value =
        case opts[:from] do
          :actor -> context.actor && context.actor.title
          :tenant -> context.tenant
          :context -> query.context[:visible_title]
        end

      Ash.Query.do_filter(query, [{opts[:field], value || "missing-context"}])
    end
  end

  defmodule Comment do
    use Ash.Resource,
      domain: AshSqlite.AggregateContextTest.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("comments")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:post_id, :uuid)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: AshSqlite.AggregateContextTest.Domain,
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

      read :for_actor do
        prepare({ContextFilter, from: :actor, field: :title})
      end

      read :for_context do
        prepare({ContextFilter, from: :context, field: :title})
      end

      read :for_argument do
        argument(:title, :string, allow_nil?: false)
        filter(expr(title == ^arg(:title)))
      end

      read :for_tenant do
        prepare({ContextFilter, from: :tenant, field: :category})
      end
    end

    relationships do
      has_many(:comments, Comment, destination_attribute: :post_id)

      has_many(:visible_links, AshSqlite.AggregateContextTest.PostLink,
        destination_attribute: :source_post_id,
        read_action: :for_actor
      )

      many_to_many :linked_posts, __MODULE__ do
        through(AshSqlite.AggregateContextTest.PostLink)
        join_relationship(:visible_links)
        source_attribute_on_join_resource(:source_post_id)
        destination_attribute_on_join_resource(:destination_post_id)
      end
    end
  end

  defmodule PostLink do
    use Ash.Resource,
      domain: AshSqlite.AggregateContextTest.Domain,
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

    actions do
      defaults([:read])

      read :for_actor do
        prepare({ContextFilter, from: :actor, field: :state})
      end
    end
  end

  defmodule Author do
    use Ash.Resource,
      domain: AshSqlite.AggregateContextTest.Domain,
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
      has_many(:source_context_posts, Post,
        destination_attribute: :author_id,
        read_action: :for_context
      )

      has_many(:context_posts, Post,
        destination_attribute: :author_id,
        read_action: :for_context,
        relationship_context: %{visible_title: "alice"}
      )

      has_many(:argument_posts, Post,
        destination_attribute: :author_id,
        read_action: :for_argument,
        read_action_arguments: %{title: "alice"}
      )

      has_many(:actor_posts, Post, destination_attribute: :author_id, read_action: :for_actor)
      has_many(:tenant_posts, Post, destination_attribute: :author_id, read_action: :for_tenant)
    end

    aggregates do
      count(:source_context_comment_count, [:source_context_posts, :comments])
      count(:context_comment_count, [:context_posts, :comments])
      count(:argument_comment_count, [:argument_posts, :comments])
      count(:actor_post_count, :actor_posts)
      count(:tenant_post_count, :tenant_posts)
      count(:actor_comment_count, [:actor_posts, :comments])
      count(:tenant_comment_count, [:tenant_posts, :comments])
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Author)
      resource(Post)
      resource(Comment)
      resource(PostLink)
    end
  end

  setup do
    author = Ash.Seed.seed!(%AshSqlite.Test.Author{first_name: "context", last_name: "test"})
    post!(author, "alice", "acme", 1)
    post!(author, "bob", "other", 2)
    %{author_id: author.id}
  end

  test "single-hop preparation receives the actor", %{author_id: id} do
    assert read!(id, :actor_post_count, actor: %{title: "alice"}).actor_post_count == 1
    assert read!(id, :actor_post_count, actor: %{title: "bob"}).actor_post_count == 1
  end

  test "single-hop preparation receives the tenant", %{author_id: id} do
    assert read!(id, :tenant_post_count, tenant: "acme").tenant_post_count == 1
    assert read!(id, :tenant_post_count, tenant: "missing").tenant_post_count == 0
  end

  test "intermediate preparation receives the actor", %{author_id: id} do
    assert read!(id, :actor_comment_count, actor: %{title: "alice"}).actor_comment_count == 1
    assert read!(id, :actor_comment_count, actor: %{title: "bob"}).actor_comment_count == 2
  end

  test "intermediate preparation receives the tenant", %{author_id: id} do
    assert read!(id, :tenant_comment_count, tenant: "acme").tenant_comment_count == 1
    assert read!(id, :tenant_comment_count, tenant: "other").tenant_comment_count == 2
  end

  test "relationship context reaches intermediate read preparations", %{author_id: id} do
    assert [_] =
             Post
             |> Ash.Query.set_context(%{visible_title: "alice"})
             |> Ash.Query.for_read(:for_context)
             |> Ash.read!()

    assert read!(id, :context_comment_count, []).context_comment_count == 1
  end

  test "relationship arguments reach intermediate read actions", %{author_id: id} do
    assert [_] = Post |> Ash.Query.for_read(:for_argument, %{title: "alice"}) |> Ash.read!()
    assert read!(id, :argument_comment_count, []).argument_comment_count == 1
  end

  test "many-to-many counts honor the join relationship read action" do
    source = Ash.Seed.seed!(%AshSqlite.Test.Post{title: "source"})

    for state <- [:active, :archived] do
      target = Ash.Seed.seed!(%AshSqlite.Test.Post{title: to_string(state)})

      Ash.Seed.seed!(%AshSqlite.Test.PostLink{
        source_post_id: source.id,
        destination_post_id: target.id,
        state: state
      })
    end

    assert [_] =
             PostLink
             |> Ash.Query.for_read(:for_actor, %{}, actor: %{title: "active"})
             |> Ash.read!()

    result =
      Post
      |> Ash.Query.filter(id == ^source.id)
      |> Ash.Query.aggregate(:visible_count, :count, :linked_posts)
      |> Ash.read_one!(actor: %{title: "active"})

    assert result.aggregates.visible_count == 1
  end

  test "shared parent context reaches intermediate preparations", %{author_id: id} do
    result =
      Author
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.set_context(%{shared: %{visible_title: "alice"}})
      |> Ash.Query.load(:source_context_comment_count)
      |> Ash.read_one!()

    assert result.source_context_comment_count == 1
  end

  defp read!(id, aggregate, opts) do
    Author |> Ash.Query.filter(id == ^id) |> Ash.Query.load(aggregate) |> Ash.read_one!(opts)
  end

  defp post!(author, title, category, comments) do
    post =
      Ash.Seed.seed!(%AshSqlite.Test.Post{
        title: title,
        category: category,
        author_id: author.id
      })

    for _ <- 1..comments do
      Ash.Seed.seed!(%AshSqlite.Test.Comment{title: "comment", post_id: post.id})
    end
  end
end
