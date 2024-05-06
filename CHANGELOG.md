# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

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
