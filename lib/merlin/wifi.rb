# frozen_string_literal: true

module Merlin
  # Switching this Mac between its usual Wi-Fi and the speaker's access point:
  #
  # 1. remember_home!  — right after talking to the Merlin API, note the
  #                      network we're on (needs Location Services, see
  #                      WifiHelper).
  # 2. join_speaker    — wait for the speaker's network to appear (the user
  #                      switches the speaker on and presses Wifi / Transfert)
  #                      and join it automatically.
  # 3. restore         — whatever the outcome, forget the speaker network and
  #                      reconnect to the remembered one.
  class Wifi
    SPEAKER_SUBNET = "192.168.4."
    ASK = "Switch the speaker on and press its Wifi / Transfert button"

    attr_reader :home_ssid, :status

    # Seconds between scans, to wait for a join to take, and before giving up
    # on the speaker's network. Overridable (tests use tiny values).
    TIMING = { poll: 3, join_wait: 20, give_up: 600 }.freeze

    class << self
      attr_writer :timing

      def timing = TIMING.merge(@timing || {})
    end

    # on_status: ->(message) for the UI's "waiting for the speaker" screen.
    def initialize(network: MacNetwork.new, out: $stdout, on_status: nil, **timing)
      @network = network
      @out = out
      @on_status = on_status
      t = self.class.timing.merge(timing)
      @poll = t[:poll]
      @join_wait = t[:join_wait]
      @give_up = t[:give_up]
    end

    def remember_home!
      ssid = @network.current_ssid
      if ssid && !ssid.match?(/\AMERLIN/i)
        @home_ssid = ssid
        say "Will reconnect to #{ssid.inspect} after the transfer."
      else
        say "Couldn't read this Mac's Wi-Fi name (Location Services for \"Merlin Wi-Fi\"?): " \
            "macOS will pick the network back after the transfer."
      end
    rescue Error => e
      say "Couldn't read this Mac's Wi-Fi name (#{e.message})."
    end

    def join_speaker(ssid, password)
      @speaker_ssid = ssid
      @speaker_password = password
      deadline = Time.now + @give_up
      say "#{ASK}: this Mac joins #{ssid} by itself as soon as it appears." unless on_speaker?
      update_status("Looking for #{ssid}…")
      until on_speaker?
        raise Error, "the speaker's Wi-Fi #{ssid} didn't show up within #{@give_up / 60} minutes" if Time.now > deadline

        nets = scan
        if nets.nil? || nets.include?(ssid) # can't scan (no permission): just try
          update_status("Found #{ssid}, joining…") if nets
          try_join
        else
          update_status("Looking for #{ssid}…")
          pause(@poll)
        end
      end
      update_status("Connected to #{ssid}")
      say "Joined the speaker's Wi-Fi #{ssid}."
    end

    # After a dropped link during the transfer: rejoin if we've left it.
    def rejoin_speaker
      return if on_speaker? || @speaker_ssid.nil?

      say "Rejoining the speaker's Wi-Fi #{@speaker_ssid}…"
      try_join
    end

    def restore
      @network.forget(@speaker_ssid) if @speaker_ssid
      if @home_ssid
        say "Reconnecting to #{@home_ssid.inspect}…"
        begin
          @network.join(@home_ssid)
        rescue Error => e
          say "Couldn't join #{@home_ssid.inspect} (#{e.message}); letting macOS reconnect."
          @network.power_cycle
        end
      else
        say "Reconnecting Wi-Fi to your usual network…"
        @network.power_cycle
      end
      wait_off_speaker
    rescue Error => e
      say "Could not reconnect automatically: #{e.message} (reconnect manually)"
    end

    private

    def on_speaker? = @network.ip.to_s.start_with?(SPEAKER_SUBNET)

    # nil when scanning isn't possible (no location permission → no names).
    def scan
      nets = @network.visible_ssids
      nets.empty? ? nil : nets
    rescue Error
      nil
    end

    def try_join
      @network.join(@speaker_ssid, @speaker_password)
      deadline = Time.now + @join_wait
      pause(1) until on_speaker? || Time.now > deadline
    rescue Error
      pause(@poll) # not there yet
    end

    def wait_off_speaker
      deadline = Time.now + @join_wait
      pause(1) while on_speaker? && Time.now < deadline
    end

    def update_status(msg)
      return if msg == @status

      @status = msg
      @on_status&.call(msg)
    end

    def pause(seconds) = sleep(seconds)
    def say(msg) = @out.puts(msg)
  end
end
