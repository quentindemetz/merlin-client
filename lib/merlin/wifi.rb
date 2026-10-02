# frozen_string_literal: true

require "open3"

module Merlin
  # Getting onto the speaker's access point. Manual mode just tells the user
  # what to join; auto mode drives macOS `networksetup`.
  class Wifi
    def initialize(auto: false, interface: nil, home_ssid: nil, input: $stdin, out: $stdout)
      @auto = auto
      @interface = interface
      @home_ssid = home_ssid
      @input = input
      @out = out
    end

    def join_speaker(ssid, password)
      if @auto && ssid
        @home_ssid ||= current_ssid
        @out.puts "Joining speaker Wi-Fi #{ssid.inspect} on #{interface}..."
        run!("networksetup", "-setairportnetwork", interface, ssid, *password)
      else
        @out.puts
        @out.puts "Turn the speaker on and press its Wifi / Transfert button, then join its Wi-Fi network"
        @out.puts ssid ? "  SSID: #{ssid}#{"   password: #{password}" if password}" : "  (named MERLIN...)"
        @out.print "Press Enter once your laptop is connected to the speaker... "
        @input.gets
      end
    end

    def restore
      return unless @auto && @home_ssid

      @out.puts "Rejoining #{@home_ssid.inspect}..."
      run!("networksetup", "-setairportnetwork", interface, @home_ssid)
    rescue Error => e
      @out.puts "Could not rejoin #{@home_ssid}: #{e.message} (reconnect manually)"
    end

    private

    def interface
      @interface ||= begin
        out, = Open3.capture2("networksetup", "-listallhardwareports")
        out[/Hardware Port: (?:Wi-Fi|AirPort)\nDevice: (\S+)/, 1] || "en0"
      end
    end

    def current_ssid
      out, = Open3.capture2("networksetup", "-getairportnetwork", interface)
      out[/Current Wi-Fi Network: (.+)$/, 1]
    end

    def run!(*cmd)
      out, status = Open3.capture2e(*cmd)
      # networksetup exits 0 even on failure but prints an error.
      raise Error, out.strip if !status.success? || out =~ /error|could not|failed/i

      out
    end
  end
end
