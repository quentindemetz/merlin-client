# frozen_string_literal: true

require_relative "test_helper"
require_relative "fake_network"
require "stringio"

class WifiTest < Minitest::Test
  def setup
    @net = FakeNetwork.new(speaker_appears_after: 3)
    @out = StringIO.new
    @statuses = []
    @wifi = Merlin::Wifi.new(network: @net, out: @out, on_status: ->(m) { @statuses << m })
  end

  def test_full_round_trip
    @wifi.remember_home!
    assert_equal "Cohen", @wifi.home_ssid

    @wifi.join_speaker("MERLIN_TEST", "pw")
    assert_equal "MERLIN_TEST", @net.ssid
    assert_equal [[:join, "MERLIN_TEST", "pw"]], @net.calls, "joins only once the network is visible"
    assert_equal ["Looking for MERLIN_TEST…", "Found MERLIN_TEST, joining…", "Connected to MERLIN_TEST"], @statuses
    assert_includes @out.string, "#{Merlin::Wifi::ASK}: this Mac joins MERLIN_TEST by itself as soon as it appears."

    @wifi.restore
    assert_equal "Cohen", @net.ssid
    assert_equal [[:forget, "MERLIN_TEST"], [:join, "Cohen", nil]], @net.calls.last(2)
  end

  def test_speaker_network_is_never_remembered_as_home
    @net.ssid = "MERLIN_DKCRG8"
    @wifi.remember_home!
    assert_nil @wifi.home_ssid
  end

  def test_without_location_permission_it_keeps_trying_to_join
    @net.can_scan = false # scans come back empty, as without Location Services
    @wifi.join_speaker("MERLIN_TEST", "pw")
    assert_equal "MERLIN_TEST", @net.ssid
    assert_operator @net.calls.count { _1[1] == "MERLIN_TEST" }, :>, 1
  end

  def test_restore_lets_macos_reconnect_when_home_is_unknown_or_fails
    @net.ssid = nil
    @wifi.remember_home!
    @wifi.join_speaker("MERLIN_TEST", "pw")
    @wifi.restore
    assert_equal [:power_cycle], @net.calls.last
    assert_equal "Cohen", @net.ssid

    wifi = Merlin::Wifi.new(network: net = FakeNetwork.new, out: StringIO.new)
    wifi.remember_home!
    wifi.join_speaker("MERLIN_TEST", "pw")
    net.join_home_fails = true
    wifi.restore
    assert_equal [:power_cycle], net.calls.last
  end

  def test_gives_up_if_the_speaker_never_appears
    wifi = Merlin::Wifi.new(network: FakeNetwork.new(speaker_appears_after: 10**9), out: StringIO.new, give_up: 0.05)
    err = assert_raises(Merlin::Error) { wifi.join_speaker("MERLIN_TEST", "pw") }
    assert_match(/didn't show up/, err.message)
  end

  def test_rejoin_only_when_off_the_speaker_network
    @net.speaker_appears_after = 0
    @wifi.join_speaker("MERLIN_TEST", "pw")
    @wifi.rejoin_speaker
    assert_equal 1, @net.calls.count { _1[0] == :join }
    @net.ssid = "Cohen" # macOS wandered off
    @wifi.rejoin_speaker
    assert_equal "MERLIN_TEST", @net.ssid
  end
end
