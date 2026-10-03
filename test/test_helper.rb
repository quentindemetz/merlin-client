# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/merlin"

# Recovery paths (reconnects, retries) run with sub-second waits in tests.
Merlin::Sync.backoff = [0.01] * Merlin::Sync::LINK_RETRIES
Merlin::Sync.link_window = 0.5
