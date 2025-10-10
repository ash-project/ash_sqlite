# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.EnumTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  require Ash.Query

  test "valid values are properly inserted" do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "title", status: :open})
    |> Ash.create!()
  end
end
