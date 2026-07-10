# frozen_string_literal: true

require "spec_helper"
require "support/vector_store_compliance"
require "maglev/vector_stores/document"
require "maglev/vector_stores/memory"

RSpec.describe Maglev::VectorStores::Memory do
  it_behaves_like "a Maglev vector store"
end
