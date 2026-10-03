# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"

module Merlin
  # Keeps the rest of this Mac's traffic away from the speaker during a
  # transfer — the root cause of the speaker crashing on macOS.
  #
  # On Android the app binds itself to the speaker network (requestNetwork +
  # bindProcessToNetwork), so the speaker only ever sees one TCP connection.
  # On macOS, joining the speaker's Wi-Fi makes it the gateway and DNS server
  # for the whole machine, and the burst of reconnecting apps / DNS / captive
  # portal probes makes the speaker reset and reboot ~15 s later.
  #
  # We install a pf rule (macOS's packet filter) that only lets our TCP session
  # and DHCP leave the Mac from the speaker's subnet. Rules live in the
  # com.apple/merlin anchor, which the stock /etc/pf.conf evaluates, and only
  # match traffic sourced from the speaker subnet. Needs admin rights (sudo).
  class Isolation
    ANCHOR = "com.apple/merlin"
    KEEPALIVE = 60 # seconds between `sudo -v` refreshes (sudo forgets after 5 min)

    # runner: ->(argv, stdin) { [output, success] } — injectable for tests.
    def initialize(state_path:, interface: nil, speaker_ip: "192.168.4.1", port: 50_000,
                   subnet: "192.168.4.0/24", runner: nil, out: $stdout)
      @state_path = state_path
      @interface = interface
      @speaker_ip = speaker_ip
      @port = port
      @subnet = subnet
      @runner = runner || method(:run_command)
      @out = out
    end

    def rules
      iface = interface
      <<~PF
        pass out quick on #{iface} proto tcp from #{@subnet} to #{@speaker_ip} port #{@port}
        pass out quick on #{iface} proto udp from any port 68 to any port 67
        block out quick on #{iface} from #{@subnet} to any
      PF
    end

    def active? = !@token.nil?
    def leftover? = File.exist?(@state_path)

    # Interactive: lets sudo ask for the admin password on the terminal, then
    # keeps the sudo session alive so enable!/disable! work non-interactively
    # however long downloads and transfers take.
    def authorize!
      raise Error, "admin rights are needed to isolate the speaker (sudo failed)" unless system("sudo", "-v")

      start_keepalive
      true
    end

    def enable!
      release_leftover
      sudo!("pfctl", "-a", ANCHOR, "-f", "-", stdin: rules)
      output = sudo!("pfctl", "-E")
      @token = output[/Token\s*:\s*(\d+)/, 1]
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.write(@state_path, JSON.generate(token: @token, interface: interface))
      @out.puts "Traffic filter on: only the transfer can reach the speaker."
      true
    end

    def disable!(keep_session: false)
      sudo!("pfctl", "-a", ANCHOR, "-F", "all")
      sudo!("pfctl", "-X", @token) if @token
      @token = nil
      FileUtils.rm_f(@state_path)
      @out.puts "Traffic filter off."
      true
    ensure
      stop_keepalive unless keep_session
    end

    # A previous run that died left rules/pf enabled: clean them up.
    def release_leftover
      return unless leftover?

      state = JSON.parse(File.read(@state_path)) rescue {}
      @token = state["token"]
      disable!(keep_session: true)
    end

    private

    def interface
      @interface ||= begin
        out, = Open3.capture2("networksetup", "-listallhardwareports")
        out[/Hardware Port: (?:Wi-Fi|AirPort)\nDevice: (\S+)/, 1] || "en0"
      end
    end

    def sudo!(*cmd, stdin: nil)
      output, ok = @runner.call(["sudo", "-n", *cmd], stdin)
      raise Error, "#{cmd.join(' ')} failed: #{output.to_s.strip}" unless ok

      output.to_s
    end

    def run_command(argv, stdin)
      out, status = Open3.capture2e(*argv, stdin_data: stdin.to_s)
      [out, status.success?]
    end

    def start_keepalive
      return if @keepalive&.alive?

      @keepalive = Thread.new do
        loop do
          sleep KEEPALIVE
          @runner.call(%w[sudo -n -v], nil)
        end
      end
      @keepalive.report_on_exception = false
    end

    def stop_keepalive
      @keepalive&.kill
      @keepalive = nil
    end
  end
end
