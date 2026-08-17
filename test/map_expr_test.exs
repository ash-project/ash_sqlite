# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MapExprTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Device

  require Ash.Query

  defp device(entity) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      id: Ash.UUID.generate(),
      name: "test",
      entity: entity
    })
    |> Ash.create!()
  end

  test "a map literal used as a fragment argument is bound as JSON" do
    device(%{"k" => "v"})
    device(%{"k" => "other"})

    found =
      Device
      |> Ash.Query.filter(fragment("json(?) = json(?)", entity, ^%{"k" => "v"}))
      |> Ash.read!()

    assert Enum.map(found, & &1.entity) == [%{"k" => "v"}]
  end

  test "a map literal used as a branch of an if is bound as JSON" do
    device(%{"k" => "v"})
    device(%{"k" => "other"})

    found =
      Device
      |> Ash.Query.filter(entity == if(is_nil(name), ^%{}, ^%{"k" => "v"}))
      |> Ash.read!()

    assert Enum.map(found, & &1.entity) == [%{"k" => "v"}]
  end

  test "a map literal nested in a boolean expression is bound as JSON" do
    device(%{"k" => "v"})
    device(%{"k" => "other"})

    found =
      Device
      |> Ash.Query.filter(
        name == "no-such-device" or fragment("json(?) = json(?)", entity, ^%{"k" => "v"})
      )
      |> Ash.read!()

    assert Enum.map(found, & &1.entity) == [%{"k" => "v"}]
  end

  test "an atomic update filtered by an expression containing a map literal runs" do
    device = device(%{"k" => "v"})
    untouched = device(%{"k" => "other"})

    Device
    |> Ash.Query.filter(fragment("json(?) = json(?)", entity, ^%{"k" => "v"}))
    |> Ash.bulk_update!(:update_entity, %{entity: %{"k" => "v2"}}, return_errors?: true)

    assert Ash.get!(Device, device.id).entity == %{"k" => "v2"}
    assert Ash.get!(Device, untouched.id).entity == %{"k" => "other"}
  end

  test "a map literal compared directly against a map attribute still works" do
    device = device(%{"k" => "v"})
    device(%{"k" => "other"})

    found =
      Device
      |> Ash.Query.filter(entity == ^%{"k" => "v"})
      |> Ash.read!()

    assert Enum.map(found, & &1.id) == [device.id]
  end
end
