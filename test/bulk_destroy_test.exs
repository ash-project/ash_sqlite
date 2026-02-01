# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
