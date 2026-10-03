# frozen_string_literal: true

require "monitor"

# Scripted stand-in for MacNetwork: the speaker's network appears after a
# number of scans; joining it gives a 192.168.4.x address.
class FakeNetwork
  include MonitorMixin

  attr_accessor :ssid, :speaker_appears_after, :can_scan, :join_home_fails, :on_join
  attr_reader :calls

  def initialize(ssid: "Cohen", speaker: "MERLIN_TEST", speaker_appears_after: 0)
    super()
    @ssid = ssid
    @speaker = speaker
    @speaker_appears_after = speaker_appears_after
    @scans = 0
    @can_scan = true
    @calls = []
  end

  def current_ssid = @ssid
  def ip = @ssid.to_s.start_with?("MERLIN") ? "192.168.4.2" : (@ssid ? "10.0.0.12" : nil)
  def speaker_visible? = @scans > @speaker_appears_after

  def visible_ssids
    synchronize { @scans += 1 }
    return [] unless can_scan

    ["Cohen", "Voisins", *(@speaker if speaker_visible?)]
  end

  def join(ssid, password = nil)
    synchronize { @calls << [:join, ssid, password] }
    if ssid == @speaker
      @scans += 1 unless can_scan # without scanning, each attempt is how we "look"
      raise Merlin::Error, "Could not find network #{ssid}." unless speaker_visible?
    elsif join_home_fails
      raise Merlin::Error, "Failed to join network #{ssid}."
    end
    @ssid = ssid
    on_join&.call(ssid)
  end

  def forget(ssid) = synchronize { @calls << [:forget, ssid] }

  def power_cycle
    synchronize { @calls << [:power_cycle] }
    @ssid = "Cohen" # macOS auto-joins the preferred network
    on_join&.call(@ssid)
  end
end
