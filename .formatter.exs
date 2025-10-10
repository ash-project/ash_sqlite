# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = [
  base_filter_sql: 1,
  code?: 1,
  deferrable: 1,
  down: 1,
  exclusion_constraint_names: 1,
  foreign_key_names: 1,
  identity_index_names: 1,
  ignore?: 1,
  include: 1,
  index: 1,
  index: 2,
  message: 1,
  migrate?: 1,
  migration_defaults: 1,
  migration_ignore_attributes: 1,
  migration_types: 1,
  name: 1,
  on_delete: 1,
  on_update: 1,
  polymorphic?: 1,
  polymorphic_name: 1,
  polymorphic_on_delete: 1,
  polymorphic_on_update: 1,
  reference: 1,
  reference: 2,
  repo: 1,
  skip_unique_indexes: 1,
  statement: 1,
  statement: 2,
  strict?: 1,
  table: 1,
  unique: 1,
  unique_index_names: 1,
  up: 1,
  using: 1,
  where: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
