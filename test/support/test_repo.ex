# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo do
  @moduledoc false
  use AshSqlite.Repo,
    otp_app: :ash_sqlite
end
