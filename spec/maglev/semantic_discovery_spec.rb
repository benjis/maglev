# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "maglev"

module SemanticDiscoveryFixtures
  Column = Data.define(:name)
  Reflection = Data.define(:name, :class_name)
  Queryable = Data.define(:scopes, :aggregates)
  Scope = Data.define(:name)
  Entry = Data.define(:identifier, :model_class, :queryable)
end

RSpec.describe Maglev::SemanticDiscovery do
  def model(name, columns: {}, enums: {}, associations: [])
    Class.new do
      define_singleton_method(:name) { name }
      define_singleton_method(:table_name) { "#{name.downcase}s" }
      define_singleton_method(:columns_hash) do
        columns.transform_values { |column| SemanticDiscoveryFixtures::Column.new(column) }
      end
      define_singleton_method(:defined_enums) { enums }
      define_singleton_method(:reflect_on_all_associations) { associations }
    end
  end

  around do |example|
    Dir.mktmpdir("maglev-semantics") do |directory|
      @root = Pathname(directory)
      example.run
    end
  end

  def write(path, source)
    destination = @root.join(path)
    FileUtils.mkdir_p(destination.dirname)
    destination.write(source)
  end

  it "combines Registry and Reflection without granting unregistered models execution" do
    account = model(
      "Account",
      columns: {id: "id", status: "status"},
      enums: {"status" => {"active" => 1}},
      associations: [SemanticDiscoveryFixtures::Reflection.new(:invoices, "Invoice")]
    )
    secret = model("SecretForecast", columns: {amount: "amount"})
    queryable = SemanticDiscoveryFixtures::Queryable.new(
      [SemanticDiscoveryFixtures::Scope.new("active_customer")],
      {sum: ["amount"]}
    )
    entry = SemanticDiscoveryFixtures::Entry.new("accounts", account, queryable)

    graph = described_class.new(root: @root, registry_entries: [entry], models: [account, secret]).call

    expect(graph.nodes.find { |node| node.id == "entity:account:account" }.execution_status).to eq(:available)
    expect(graph.nodes.find { |node| node.id == "entity:secret_forecast:secret_forecast" }.execution_status).to eq(:unavailable)
    expect(graph.nodes.map(&:id)).to include(
      "dimension:account:status",
      "state:account:active",
      "term:account:active_customer",
      "metric:account:sum_amount"
    )
    expect(graph.evidence.map(&:source_kind)).to include(:registry, :reflection, :schema)
  end

  it "uses Prism to discover representative repository-wide semantics with provenance" do
    write("app/queries/monthly_recurring_revenue_query.rb", <<~RUBY)
      class MonthlyRecurringRevenueQuery
        semantic_context :billing
        semantic_metric :monthly_recurring_revenue
        semantic_dimension :plan
        semantic_business_rule :billable_subscription

        def call
          Subscription.billable.sum(:monthly_price)
        end
      end
    RUBY
    write("app/models/customer.rb", <<~RUBY)
      class Customer < ApplicationRecord
        enum :status, active: 0, churned: 1
        scope :active_customer, -> { where(status: :active) }
        validates :email, presence: true

        def active?
          status == "active"
        end

        def churn!
          self.status = :churned
        end
      end
    RUBY
    write("app/models/lead.rb", <<~RUBY)
      class Lead < ApplicationRecord
        scope :active_customer, -> { where(converted_at: nil) }
      end
    RUBY
    write("app/services/renew_subscription_service.rb", <<~RUBY)
      class RenewSubscriptionService
        semantic_action :renew_subscription
        semantic_transition :renewed
      end
    RUBY

    graph = described_class.new(root: @root, registry_entries: [], models: []).call

    expect(graph.nodes.map(&:kind).uniq).to include(*Maglev::SemanticGraph::Node::KINDS)
    expect(graph.nodes.map(&:id)).to include(
      "metric:billing:monthly_recurring_revenue",
      "term:customer:active_customer",
      "term:lead:active_customer",
      "state:customer:active",
      "state:customer:churned",
      "transition:customer:to_churned",
      "semantic_context:billing:billing",
      "entity:customer:customer",
      "action:renew_subscription_service:renew_subscription"
    )
    evidence = graph.evidence.find { |item| item.stable_identity == "ruby:Customer.scope.active_customer" }
    expect(evidence.file).to eq("app/models/customer.rb")
    expect(evidence.line).to eq(3)
    expect(evidence.digest).to match(/\A[0-9a-f]{64}\z/)
    expect(graph.nodes.grep_v(nil).all? { |node| node.execution_status == :unavailable }).to be(true)
    expect(graph.inspect).not_to include("where(status")
  end

  it "reconstructs a simple metric only when its aggregate and scope already exist in Registry authority" do
    subscription = model("Subscription", columns: {monthly_price: "monthly_price"})
    queryable = SemanticDiscoveryFixtures::Queryable.new(
      [SemanticDiscoveryFixtures::Scope.new("billable")],
      {sum: ["monthly_price"]}
    )
    entry = SemanticDiscoveryFixtures::Entry.new("subscriptions", subscription, queryable)
    write("app/queries/monthly_recurring_revenue_query.rb", <<~RUBY)
      class MonthlyRecurringRevenueQuery
        semantic_context :billing
        semantic_metric :monthly_recurring_revenue

        def call
          Subscription.billable.sum(:monthly_price)
        end
      end
    RUBY

    graph = described_class.new(root: @root, registry_entries: [entry], models: [subscription]).call
    metric = graph.nodes.find { |node| node.id == "metric:billing:monthly_recurring_revenue" }
    term = graph.nodes.find { |node| node.id == "term:billing:billable" }

    expect(metric.execution_status).to eq(:available)
    expect(term.execution_status).to eq(:available)
    expect(graph.evidence.map(&:stable_identity)).to include(
      "aggregate:subscriptions.sum.monthly_price",
      "scope:subscriptions.billable"
    )
  end

  it "keeps test prose from becoming observed truth" do
    write("spec/models/customer_spec.rb", <<~RUBY)
      RSpec.describe Customer do
        semantic_term :vip_customer
        it "defines a highly profitable customer" do
          expect(true).to be(true)
        end
      end
    RUBY

    graph = described_class.new(root: @root, registry_entries: [], models: []).call
    term = graph.nodes.find { |node| node.name == "vip_customer" }

    expect(graph.semantic_status_for(term.id)).to eq(:reconstructed)
    expect(graph.evidence.map(&:source_kind)).to eq([:test])
    expect(graph.nodes.map(&:name)).not_to include("highly_profitable_customer")
  end
end
