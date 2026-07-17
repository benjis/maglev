# frozen_string_literal: true

require "spec_helper"
require "maglev/chunker"

RSpec.describe Maglev::Chunker do
  it "returns deterministic chunks under the configured character budget" do
    text = <<~TEXT
      Customer#123
      name: Acme Pty Ltd

      industry: Retail
      description: Long term customer with repeated support problems.
    TEXT

    chunks = described_class.new(max_characters: 55).call(text)

    expect(chunks).to eq([
      "Customer#123\nname: Acme Pty Ltd",
      "industry: Retail",
      "description: Long term customer with repeated support",
      "problems."
    ])
  end

  it "drops blank chunks" do
    expect(described_class.new(max_characters: 10).call("\n\n")).to eq([])
  end

  it "hard-splits Chinese text without whitespace" do
    text = "这是一个没有空格的中文句子"

    expect(described_class.new(max_characters: 5).call(text)).to eq([
      "这是一个没",
      "有空格的中",
      "文句子"
    ])
  end

  it "hard-splits Japanese text without whitespace" do
    text = "これは空白のない日本語の文章です"

    expect(described_class.new(max_characters: 6).call(text)).to eq([
      "これは空白の",
      "ない日本語の",
      "文章です"
    ])
  end

  it "hard-splits a single long URL" do
    text = "https://example.com/a/very/long/path?token=abcdef"
    chunks = described_class.new(max_characters: 12).call(text)

    expect(chunks.join).to eq(text)
    expect(chunks).to all(satisfy { |chunk| chunk.length <= 12 })
  end

  it "hard-splits a base64-like token" do
    text = "U29tZVJlYWxseUxvbmdCYXNlNjRMaWtlVG9rZW4="
    chunks = described_class.new(max_characters: 9).call(text)

    expect(chunks.join).to eq(text)
    expect(chunks).to all(satisfy { |chunk| chunk.length <= 9 })
  end

  it "preserves a normal line before hard-splitting an oversized line" do
    text = "normal\nabcdefghijklmnopqrstuvwxyz"

    expect(described_class.new(max_characters: 10).call(text)).to eq([
      "normal",
      "abcdefghij",
      "klmnopqrst",
      "uvwxyz"
    ])
  end

  it "hard-splits an oversized first line before preserving following lines" do
    text = "abcdefghijklmnopqrstuvwxyz\nnormal"

    expect(described_class.new(max_characters: 10).call(text)).to eq([
      "abcdefghij",
      "klmnopqrst",
      "uvwxyz",
      "normal"
    ])
  end

  it "keeps text exactly at the character budget and splits one character over" do
    chunker = described_class.new(max_characters: 5)

    expect(chunker.call("abcde")).to eq(["abcde"])
    expect(chunker.call("abcdef")).to eq(["abcde", "f"])
  end

  it "prefers grapheme-cluster boundaries when hard-splitting" do
    text = "e\u0301e\u0301e\u0301"

    expect(described_class.new(max_characters: 4).call(text)).to eq(["e\u0301e\u0301", "e\u0301"])
  end

  it "rejects non-positive max_characters" do
    expect { described_class.new(max_characters: 0) }
      .to raise_error(ArgumentError, "max_characters must be positive")
    expect { described_class.new(max_characters: -1) }
      .to raise_error(ArgumentError, "max_characters must be positive")
  end
end
