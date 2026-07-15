# Maglev Dummy Application

This Rails application hosts the reusable e-commerce domain used by Maglev integration tests. It uses PostgreSQL, pgvector, Active Storage, Action Text, and deterministic three-dimensional embedding and generation adapters. It never needs provider credentials.

From `spec/dummy`, prepare and load the complete diagnostic graph:

```bash
RAILS_ENV=test bundle exec ruby bin/rails db:prepare
RAILS_ENV=test bundle exec ruby bin/rails db:seed
```

The seed task is intentionally destructive and re-runnable. It rebuilds the same products, customers, orders, reviews, comments, attachments, and rich text without loading them before every RSpec example.

To seed and synchronously index every knowledge-enabled model:

```bash
RAILS_ENV=test bundle exec ruby bin/rails db:seed maglev:reindex_all
```

Inspect a real snapshot or run a grounded query with the fake adapters:

```bash
RAILS_ENV=test bundle exec ruby bin/rails runner 'puts Product.find_by!(sku: "ELEC-001").maglev_snapshot'
RAILS_ENV=test bundle exec ruby bin/rails runner 'puts Product.find_by!(sku: "ELEC-001").ask("What is this product suited for?", limit: 3).text'
```

Focused automated coverage remains isolated and creates only the records it needs:

```bash
cd ../..
bundle exec rspec spec/integration/dummy_ecommerce_domain_spec.rb
```
