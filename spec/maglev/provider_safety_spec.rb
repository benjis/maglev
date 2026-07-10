# frozen_string_literal: true

require "spec_helper"
require "maglev/provider_call"

RSpec.describe Maglev::ProviderCall do
  it "retries retryable provider failures and emits notifications" do
    attempts = 0
    events = []
    subscription = ActiveSupport::Notifications.subscribe("maglev.provider.retry") do |_name, _start, _finish, _id, payload|
      events << payload
    end

    result = described_class.new(max_attempts: 2).call(operation: "embed") do
      attempts += 1
      raise Maglev::RetryableProviderError, "timeout" if attempts == 1

      "ok"
    end

    expect(result).to eq("ok")
    expect(events.first).to include(operation: "embed", attempt: 1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "does not retry permanent provider failures" do
    attempts = 0

    expect do
      described_class.new(max_attempts: 3).call(operation: "generate") do
        attempts += 1
        raise Maglev::PermanentProviderError, "bad request"
      end
    end.to raise_error(Maglev::PermanentProviderError)

    expect(attempts).to eq(1)
  end
end
