# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.BulkUpdateTest do
  use AshSqlite.RepoCase, async: false
  require Ash.Query
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

  test "atomic bulk updates persist attributes set to the resource default" do
    alias AshSqlite.Test.Device

    device =
      Device
      |> Ash.Changeset.for_create(:create, %{id: "1", name: "test", entity: %{}})
      |> Ash.Changeset.force_change_attribute(:status, :inactive)
      |> Ash.create!()

    assert device.status == :inactive

    Device
    |> Ash.Query.filter(id == ^device.id)
    |> Ash.bulk_update!(:update_status, %{status: :active}, return_errors?: true)

    reloaded = Ash.get!(Device, device.id)

    assert reloaded.status == :active
  end
end
