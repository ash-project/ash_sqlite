defmodule AshSqlite.Test.ManualRelationshipsTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Api, Comment, Post}

  require Ash.Query

  describe "manual first" do
    test "relationships can be filtered on with no data" do
      Post
      |> Ash.Changeset.new(%{title: "title"})
      |> Api.create!()

      assert [] =
               Post |> Ash.Query.filter(comments_containing_title.title == "title") |> Api.read!()
    end

    test "relationships can be filtered on with data" do
      post =
        Post
        |> Ash.Changeset.new(%{title: "title"})
        |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "title2"})
      |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "title2"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      assert [_] =
               Post
               |> Ash.Query.filter(comments_containing_title.title == "title2")
               |> Api.read!()
    end
  end

  describe "manual last" do
    test "relationships can be filtered on with no data" do
      post =
        Post
        |> Ash.Changeset.new(%{title: "title"})
        |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      assert [] =
               Comment
               |> Ash.Query.filter(post.comments_containing_title.title == "title2")
               |> Api.read!()
    end

    test "relationships can be filtered on with data" do
      post =
        Post
        |> Ash.Changeset.new(%{title: "title"})
        |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "title2"})
      |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "title2"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      assert [_, _] =
               Comment
               |> Ash.Query.filter(post.comments_containing_title.title == "title2")
               |> Api.read!()
    end
  end

  describe "manual middle" do
    test "relationships can be filtered on with data" do
      post =
        Post
        |> Ash.Changeset.new(%{title: "title"})
        |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "title2"})
      |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "title2"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      Comment
      |> Ash.Changeset.new(%{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Api.create!()

      assert [_, _] =
               Comment
               |> Ash.Query.filter(post.comments_containing_title.post.title == "title")
               |> Api.read!()
    end
  end
end
