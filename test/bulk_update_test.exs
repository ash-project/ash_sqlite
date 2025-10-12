# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.BulkUpdateTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  test "bulk updates honor update action filters" do
    Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create)

    Post
    |> Ash.bulk_update!(:update_only_freds, %{title: "fred_stuff"}, return_errors?: true)

    titles =
      Post
      |> Ash.read!()
      |> Enum.map(& &1.title)
      |> Enum.sort()

    assert titles == ["fred_stuff", "george"]
  end
end
