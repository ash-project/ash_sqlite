defmodule AshSqlite.BulkDestroyTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  test "bulk destroys honor changeset filters" do
    Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create)

    Post
    |> Ash.bulk_destroy!(:destroy_only_freds, %{}, return_errors?: true)

    # 😢 sad
    assert ["george"] = Ash.read!(Post) |> Enum.map(& &1.title)
  end
end
