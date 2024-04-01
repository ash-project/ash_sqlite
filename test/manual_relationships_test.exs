defmodule AshSqlite.Test.ManualRelationshipsTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Comment, Post}

  require Ash.Query

  describe "manual first" do
    test "relationships can be filtered on with no data" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title"})
      |> Ash.create!()

      assert [] =
               Post |> Ash.Query.filter(comments_containing_title.title == "title") |> Ash.read!()
    end

    test "relationships can be filtered on with data" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      assert [_] =
               Post
               |> Ash.Query.filter(comments_containing_title.title == "title2")
               |> Ash.read!()
    end
  end

  describe "manual last" do
    test "relationships can be filtered on with no data" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      assert [] =
               Comment
               |> Ash.Query.filter(post.comments_containing_title.title == "title2")
               |> Ash.read!()
    end

    test "relationships can be filtered on with data" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      assert [_, _] =
               Comment
               |> Ash.Query.filter(post.comments_containing_title.title == "title2")
               |> Ash.read!()
    end
  end

  describe "manual middle" do
    test "relationships can be filtered on with data" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "no match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      assert [_, _] =
               Comment
               |> Ash.Query.filter(post.comments_containing_title.post.title == "title")
               |> Ash.read!()
    end
  end
end
