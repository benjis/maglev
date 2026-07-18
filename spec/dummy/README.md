# Maglev Dummy Application

This Rails application hosts reusable e-commerce and billing/support domains used by Maglev integration tests. It uses PostgreSQL, pgvector, Active Storage, Action Text, and deterministic three-dimensional embedding and generation adapters. It never needs provider credentials.

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
bundle exec rspec spec/integration/dummy_billing_support_domain_spec.rb
```

## Authorization base relations

Maglev does not depend on a policy library. Convert the library's authorized
scope into the base relation passed to planning or the unified request API.

```ruby
# Plain tenant relation
base = current_account.invoices
base.maglev_request(question, mode: :structured, planner_adapter: planner)

# Pundit
base = InvoicePolicy::Scope.new(current_user, Invoice).resolve
base.maglev_request(question, mode: :structured, planner_adapter: planner)

# CanCanCan
base = Invoice.accessible_by(current_ability)
base.maglev_request(question, mode: :structured, planner_adapter: planner)
```

The planner cannot remove account/policy predicates from any of these relations.
Keep `authorization :required` for tenant-owned resources and never replace the
authorized relation with `Invoice.all`.
