# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.LoadTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Comment, Post}

  require Ash.Query

  test "has_many relationships can be loaded" do
    assert %Post{comments: %Ash.NotLoaded{type: :relationship}} =
             post =
             Post
             |> Ash.Changeset.for_create(:create, %{title: "title"})
             |> Ash.create!()

    Comment
    |> Ash.Changeset.for_create(:create, %{title: "match"})
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()

    results =
      Post
      |> Ash.Query.load(:comments)
      |> Ash.read!()

    assert [%Post{comments: [%{title: "match"}]}] = results
  end

  test "belongs_to relationships can be loaded" do
    assert %Comment{post: %Ash.NotLoaded{type: :relationship}} =
             comment =
             Comment
             |> Ash.Changeset.for_create(:create, %{})
             |> Ash.create!()

    Post
    |> Ash.Changeset.for_create(:create, %{title: "match"})
    |> Ash.Changeset.manage_relationship(:comments, [comment], type: :append_and_remove)
    |> Ash.create!()

    results =
      Comment
      |> Ash.Query.load(:post)
      |> Ash.read!()

    assert [%Comment{post: %{title: "match"}}] = results
  end

  test "many_to_many loads work" do
    source_post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "source"})
      |> Ash.create!()

    destination_post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "destination"})
      |> Ash.create!()

    destination_post2 =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "destination"})
      |> Ash.create!()

    source_post
    |> Ash.Changeset.new()
    |> Ash.Changeset.manage_relationship(:linked_posts, [destination_post, destination_post2],
      type: :append_and_remove
    )
    |> Ash.update!()

    results =
      source_post
      |> Ash.load!(:linked_posts)

    assert %{linked_posts: [%{title: "destination"}, %{title: "destination"}]} = results
  end

  test "many_to_many loads work when nested" do
    source_post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "source"})
      |> Ash.create!()

    destination_post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "destination"})
      |> Ash.create!()

    source_post
    |> Ash.Changeset.new()
    |> Ash.Changeset.manage_relationship(:linked_posts, [destination_post],
      type: :append_and_remove
    )
    |> Ash.update!()

    destination_post
    |> Ash.Changeset.new()
    |> Ash.Changeset.manage_relationship(:linked_posts, [source_post], type: :append_and_remove)
    |> Ash.update!()

    results =
      source_post
      |> Ash.load!(linked_posts: :linked_posts)

    assert %{linked_posts: [%{title: "destination", linked_posts: [%{title: "source"}]}]} =
             results
  end

  describe "lateral join loads" do
    # uncomment when lateral join is supported
    # it does not necessarily have to be implemented *exactly* as lateral join
    # test "parent references are resolved" do
    #   post1 =
    #     Post
    #     |> Ash.Changeset.new(%{title: "title"})
    #     |> Api.create!()

    #   post2 =
    #     Post
    #     |> Ash.Changeset.new(%{title: "title"})
    #     |> Api.create!()

    #   post2_id = post2.id

    #   post3 =
    #     Post
    #     |> Ash.Changeset.new(%{title: "no match"})
    #     |> Api.create!()

    #   assert [%{posts_with_matching_title: [%{id: ^post2_id}]}] =
    #            Post
    #            |> Ash.Query.load(:posts_with_matching_title)
    #            |> Ash.Query.filter(id == ^post1.id)
    #            |> Api.read!()

    #   assert [%{posts_with_matching_title: []}] =
    #            Post
    #            |> Ash.Query.load(:posts_with_matching_title)
    #            |> Ash.Query.filter(id == ^post3.id)
    #            |> Api.read!()
    # end

    # test "parent references work when joining for filters" do
    #   %{id: post1_id} =
    #     Post
    #     |> Ash.Changeset.new(%{title: "title"})
    #     |> Api.create!()

    #   post2 =
    #     Post
    #     |> Ash.Changeset.new(%{title: "title"})
    #     |> Api.create!()

    #   Post
    #   |> Ash.Changeset.new(%{title: "no match"})
    #   |> Api.create!()

    #   Post
    #   |> Ash.Changeset.new(%{title: "no match"})
    #   |> Api.create!()

    #   assert [%{id: ^post1_id}] =
    #            Post
    #            |> Ash.Query.filter(posts_with_matching_title.id == ^post2.id)
    #            |> Api.read!()
    # end

    # test "lateral join loads (loads with limits or offsets) are supported" do
    #   assert %Post{comments: %Ash.NotLoaded{type: :relationship}} =
    #            post =
    #            Post
    #            |> Ash.Changeset.new(%{title: "title"})
    #            |> Api.create!()

    #   Comment
    #   |> Ash.Changeset.new(%{title: "abc"})
    #   |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    #   |> Api.create!()

    #   Comment
    #   |> Ash.Changeset.new(%{title: "def"})
    #   |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    #   |> Api.create!()

    #   comments_query =
    #     Comment
    #     |> Ash.Query.limit(1)
    #     |> Ash.Query.sort(:title)

    #   results =
    #     Post
    #     |> Ash.Query.load(comments: comments_query)
    #     |> Api.read!()

    #   assert [%Post{comments: [%{title: "abc"}]}] = results

    #   comments_query =
    #     Comment
    #     |> Ash.Query.limit(1)
    #     |> Ash.Query.sort(title: :desc)

    #   results =
    #     Post
    #     |> Ash.Query.load(comments: comments_query)
    #     |> Api.read!()

    #   assert [%Post{comments: [%{title: "def"}]}] = results

    #   comments_query =
    #     Comment
    #     |> Ash.Query.limit(2)
    #     |> Ash.Query.sort(title: :desc)

    #   results =
    #     Post
    #     |> Ash.Query.load(comments: comments_query)
    #     |> Api.read!()

    #   assert [%Post{comments: [%{title: "def"}, %{title: "abc"}]}] = results
    # end

    test "loading many to many relationships on records works without loading its join relationship when using code interface" do
      source_post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "source"})
        |> Ash.create!()

      destination_post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "abc"})
        |> Ash.create!()

      destination_post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "def"})
        |> Ash.create!()

      source_post
      |> Ash.Changeset.new()
      |> Ash.Changeset.manage_relationship(:linked_posts, [destination_post, destination_post2],
        type: :append_and_remove
      )
      |> Ash.update!()

      assert %{linked_posts: [_, _]} = Post.get_by_id!(source_post.id, load: [:linked_posts])
    end
  end
end
