# frozen_string_literal: true

module Maglev
  class ProviderConfiguration
    attr_accessor :url, :api_key, :model, :dimensions

    def initialize(url: nil, api_key: nil, model: nil, dimensions: nil)
      @url = url
      @api_key = api_key
      @model = model
      @dimensions = dimensions
    end

    def to_h
      {url: url, api_key: api_key, model: model, dimensions: dimensions}.compact
    end
  end
end
