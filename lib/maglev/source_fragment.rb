# frozen_string_literal: true

module Maglev
  SourceFragment = Data.define(:identity, :type, :content) do
    def initialize(identity:, type:, content:)
      super(identity: identity.to_s.freeze, type: type.to_sym, content: content.to_s.freeze)
    end
  end
end
