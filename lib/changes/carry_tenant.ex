# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Changes.CarryTenant do
  @moduledoc """
  Puts the tenant in `context[:data_layer]`, where `AshSqlite.DataLayer.transaction/4` can reach it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> put_tenant()
    |> Ash.Changeset.before_transaction(&put_tenant/1)
  end

  defp put_tenant(%{tenant: nil} = changeset), do: changeset

  defp put_tenant(changeset) do
    Ash.Changeset.set_context(changeset, %{data_layer: %{tenant: changeset.tenant}})
  end

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}
end
