# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "action_text/engine"

require "maglev"

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.1
    config.active_support.to_time_preserves_timezone = :zone
    config.active_storage.service = :test
    config.eager_load = false
    config.root = File.expand_path("..", __dir__)
  end
end
