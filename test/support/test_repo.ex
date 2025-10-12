# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo do
  @moduledoc false
  use AshSqlite.Repo,
    otp_app: :ash_sqlite
end
