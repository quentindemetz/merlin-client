# frozen_string_literal: true

require "open3"

module Merlin
  # Location Services for the "Merlin Wi-Fi" helper, checked up front (CLI
  # sync and TUI startup) so macOS's dialog appears while the user is there.
  module WifiPermission
    module_function

    def check(network, out: $stdout)
      return unless network.respond_to?(:location_authorized?)

      out.puts "Checking Location Services for \"Merlin Wi-Fi\" (it reads the Wi-Fi name to switch to the " \
               "speaker and back). If macOS asks, click Allow."
      if network.location_authorized?
        out.puts "Location access OK."
      else
        out.puts "No location access: this Mac will keep trying to join the speaker and let macOS pick your " \
                 "network back afterwards. Enable it in System Settings › Privacy & Security › Location Services " \
                 "› Merlin Wi-Fi."
        sleep 2
      end
    rescue Error => e
      out.puts "Couldn't check Location Services (#{e.message})."
    end
  end

  # The macOS operations Wifi needs, in one place (tests use a fake).
  class MacNetwork
    def initialize(helper: WifiHelper.new, interface: nil)
      @helper = helper
      @interface = interface
    end

    def interface
      @interface ||= begin
        out, = Open3.capture2("networksetup", "-listallhardwareports")
        out[/Hardware Port: (?:Wi-Fi|AirPort)\nDevice: (\S+)/, 1] || "en0"
      end
    end

    def location_authorized? = @helper.authorized?
    def current_ssid = @helper.current_ssid
    def visible_ssids = @helper.scan

    def ip
      out, = Open3.capture2("ipconfig", "getifaddr", interface)
      out.strip.then { _1.empty? ? nil : _1 }
    end

    # Joins a network; for a known network the password comes from the keychain.
    def join(ssid, password = nil)
      run!("networksetup", "-setairportnetwork", interface, ssid, *password)
    end

    # So macOS doesn't auto-join the speaker's access point later.
    def forget(ssid)
      Open3.capture2e("networksetup", "-removepreferredwirelessnetwork", interface, ssid)
    end

    # Makes macOS auto-join its preferred network (used when the previous
    # network's name couldn't be read).
    def power_cycle
      run!("networksetup", "-setairportpower", interface, "off")
      sleep 3
      run!("networksetup", "-setairportpower", interface, "on")
    end

    private

    def run!(*cmd)
      out, status = Open3.capture2e(*cmd)
      # networksetup exits 0 even on failure but prints an error.
      raise Error, out.strip if !status.success? || out =~ /error|could not|failed/i

      out
    end
  end
end
