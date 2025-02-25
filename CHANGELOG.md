# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.2.4](https://github.com/ash-project/ash_sqlite/compare/v0.2.3...v0.2.4) (2025-02-25)




### Bug Fixes:

* remove list literal usage for `in` in ash_sqlite

## [v0.2.3](https://github.com/ash-project/ash_sqlite/compare/v0.2.2...v0.2.3) (2025-01-26)




### Bug Fixes:

* use `AshSql` for running aggregate queries

### Improvements:

* update ash version for better aggregate support validation

## [v0.2.2](https://github.com/ash-project/ash_sqlite/compare/v0.2.1...v0.2.2) (2025-01-22)




### Bug Fixes:

* Remove a postgresql specific configuration from `ash_sqlite.install` (#103)

### Improvements:

* add installer for sqlite

* make igniter optional

* improve dry_run logic and fix priv path setup

* honor repo configs and add snapshot configs

## [v0.2.1](https://github.com/ash-project/ash_sqlite/compare/v0.2.0...v0.2.1) (2024-10-09)




### Bug Fixes:

* don't raise error on codegen with no domains

* installer: use correct module name in the `DataCase` moduledocs. (#82)

### Improvements:

* add `--repo` option to installer, warn on clashing existing repo

* modify mix task aliases according to installer

## [v0.2.0](https://github.com/ash-project/ash_sqlite/compare/v0.1.3...v0.2.0) (2024-09-10)




### Features:

* add igniter-based AshSqlite.Install mix task (#66)

### Improvements:

* fix warnings from latest igniter updates

## [v0.1.3](https://github.com/ash-project/ash_sqlite/compare/v0.1.2...v0.1.3) (2024-05-31)




### Bug Fixes:

* use `Ecto.ParameterizedType.init/2`

* handle new/old ecto parameterized type format

## [v0.1.2](https://github.com/ash-project/ash_sqlite/compare/v0.1.2-rc.1...v0.1.2) (2024-05-11)




## [v0.1.2-rc.1](https://github.com/ash-project/ash_sqlite/compare/v0.1.2-rc.0...v0.1.2-rc.1) (2024-05-06)




### Bug Fixes:

* properly scope deletes to the records in question

* update ash_sqlite to get `ilike` behavior fix

### Improvements:

* support `contains` function

## [v0.1.2-rc.0](https://github.com/ash-project/ash_sqlite/compare/v0.1.1...v0.1.2-rc.0) (2024-04-15)




### Bug Fixes:

* reenable mix tasks that we need to call

### Improvements:

* support `mix ash.rollback`

* support Ash 3.0, leverage `ash_sql` package

* fix datetime migration type discovery

## [v0.1.1](https://github.com/ash-project/ash_sqlite/compare/v0.1.0...v0.1.1) (2023-10-12)




### Improvements:

* add `SqliteMigrationDefault`

* support query aggregates

## [v0.1.0](https://github.com/ash-project/ash_sqlite/compare/v0.1.0...v0.1.0) (2023-10-12)


### Improvements:

* Port and adjust `AshPostgres` to `AshSqlite`
