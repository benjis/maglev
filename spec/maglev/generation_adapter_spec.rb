# frozen_string_literal: true

require "spec_helper"
require "maglev/generation_adapter"

RSpec.describe Maglev::GenerationAdapter do
  it "requires subclasses to implement generation" do
    expect { described_class.new.generate("prompt") }
      .to raise_error(NotImplementedError, /must implement #generate/)
  end
end
