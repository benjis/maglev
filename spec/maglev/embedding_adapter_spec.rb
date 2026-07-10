# frozen_string_literal: true

require "spec_helper"
require "maglev/embedding_adapter"

RSpec.describe Maglev::EmbeddingAdapter do
  it "requires concrete adapters to implement embed" do
    expect { described_class.new.embed("query") }.to raise_error(NotImplementedError, /embed/)
  end
end
