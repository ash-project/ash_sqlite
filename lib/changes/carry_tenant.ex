# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Changes.CarryTenant do
  @moduledoc """
  Copies the changeset's tenant into `context[:data_layer]`.

  This exists for one callback. `Ash.DataLayer.transaction/4` runs *above* the data
  layer — it has to, because a transaction spans every statement an action issues —
  and the only part of the changeset Ash forwards to it is `context[:data_layer]`.
  Nothing else in the transaction reason names a tenant: a create carries `resource`,
  `action` and `actor`, and its `data_layer_context` is empty.

  So without this, `AshSqlite.DataLayer.transaction/4` cannot know which database to
  open a `BEGIN` against, and a database-per-tenant layout has no default worth
  guessing. Every other callback reads the tenant off the changeset or the query
  directly and needs nothing from here.

  Added automatically by `AshSqlite.Transformers.CarryTenant` to resources that have
  both a `tenant_binder` and `strategy :context`, so it is invisible to everyone else.

  ## Why this does not force actions off the atomic path

  Ash calls `c:Ash.Resource.Change.atomic/3` rather than
  `c:Ash.Resource.Change.change/3` whenever it can build a single statement, and a
  change implementing only `change/3` would force `require_atomic? false` on every
  update that used it. This implements both. `atomic/3` returns the changeset
  untouched, which is correct as well as cheap: a single statement is already atomic,
  and `c:Ash.DataLayer.prefer_transaction_for_atomic_updates?/1` is false, so no
  transaction is opened for it and there is nothing for the tenant to reach.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.set_context(changeset, %{data_layer: %{tenant: changeset.tenant}})
  end

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}
end
