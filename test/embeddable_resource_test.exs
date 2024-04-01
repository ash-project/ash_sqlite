defmodule AshSqlite.EmbeddableResourceTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Author, Bio, Post}

  require Ash.Query

  setup do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title"})
      |> Ash.create!()

    %{post: post}
  end

  test "calculations can load json", %{post: post} do
    assert %{calc_returning_json: %AshSqlite.Test.Money{amount: 100, currency: :usd}} =
             Ash.load!(post, :calc_returning_json)
  end

  test "embeds with list attributes set to nil are loaded as nil" do
    post =
      Author
      |> Ash.Changeset.for_create(:create, %{bio: %Bio{list_of_strings: nil}})
      |> Ash.create!()

    assert is_nil(post.bio.list_of_strings)

    post = Ash.reload!(post)

    assert is_nil(post.bio.list_of_strings)
  end
end
