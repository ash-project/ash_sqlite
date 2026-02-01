# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.DevTestRepo do
  @moduledoc false
  use AshSqlite.Repo,
    otp_app: :ash_sqlite

  def on_transaction_begin(data) do
    send(self(), data)
  end

  def prefer_transaction?, do: false

  def prefer_transaction_for_atomic_updates?, do: false
end
