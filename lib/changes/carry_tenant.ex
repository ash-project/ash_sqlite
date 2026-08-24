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
    # Also as a before_transaction hook, because a tenant given to `Ash.create/3`
    # rather than to `Ash.Changeset.for_create/4` is applied after global changes
    # have run -- and those hooks run on the changeset the transaction is opened
    # with.
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
