# Changelog

All notable changes are documented here. Maglev follows Semantic Versioning.

## [0.2.1] - 2026-07-21

### Fixed

- Added the documented `maglev-rb` require entry point and tightened release metadata coverage.
- Preserved structured query values through planner serialization and compilation, including association paths.
- Improved resource registration validation and made index diagnostics updates safer.

## [0.2.0] - 2026-07-19

### Added

- Explicit `maglev_resource` registration for structured query fields, associations, scopes, aggregates, limits, authorization policy, and knowledge sources.
- Immutable Query IR v1, deterministic validation, ActiveRecord-first compilation on an authorized base relation, bounded read-only execution, structured evidence, and redacted traces.
- Provider-neutral planning, explicit intent routing, a unified request/result envelope, inspectable source-aware RAG retrieval, and two fixed hybrid workflows.
- Source identity and index diagnostics with reversible migration generators and deterministic provider-free evaluation fixtures.

### Changed

- Ruby 3.3 is now the minimum supported Ruby version; CI covers Ruby 3.3/4.0 and Rails 7.1/8.0.
- Vector stores receive validated source/tenant/authorization filters and must preserve atomic owner replacement semantics.
- `maglev_resource` is the only model DSL. Use its `queryable` block for structured ActiveRecord queries and its `knowledge` block for RAG; the pre-release `has_knowledge` DSL was removed without a compatibility alias.

### Security

- Structured compilation can only narrow the supplied base relation and rejects SQL, Ruby, Arel, unregistered fields/scopes, writes, locks, and relation widening.
- Evidence and traces are bounded and redact record values, source text, secrets, and raw provider payloads by default.

### Upgrade from 0.1.x

1. Upgrade the gem and run `bin/rails generate maglev:upgrade_index_version` if the existing installation has no `index_version` column.
2. Run `bin/rails generate maglev:upgrade_source_identity` to add source identity, tenant filtering metadata, and index diagnostics state.
3. Review both generated migrations, adapt owner key types when the application uses UUIDs, and run `bin/rails db:migrate`.
4. If embedding dimensions changed, migrate the pgvector column and rebuild its HNSW index before reindexing.
5. Run `bin/rails maglev:reindex_all`. Legacy rows are intentionally unavailable until the full reindex completes.
6. Replace every `has_knowledge` declaration with `maglev_resource :identifier do ... knowledge do ... end ... end`. No compatibility alias is provided. Model `search` and record/model `ask` remain available on resources that declare `knowledge`.

Rollback requires migrating the source-identity migration down, restoring the prior gem version, and performing a full reindex. Never reuse a partially upgraded index across versions.

## [0.1.4] - 2026-07-18

- Hardened the RAG correctness, lifecycle, and index identity baseline.
