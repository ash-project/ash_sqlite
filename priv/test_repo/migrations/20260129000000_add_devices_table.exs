# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo.Migrations.AddDevicesTable do
  use Ecto.Migration

  def up do
    create table(:devices, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :name, :text, null: false
      add :entity, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:devices, [:id], name: "devices_unique_id_index")
  end

  def down do
    drop_if_exists unique_index(:devices, [:id], name: "devices_unique_id_index")
    drop table(:devices)
  end
end
