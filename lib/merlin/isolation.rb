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
  # match traffic sourced from the speaker subnet.
  #
  # Admin rights: sudo may be configured never to cache credentials
  # (`Defaults timestamp_timeout=0`, common on managed Macs), so instead of
  # several sudo calls we start one small root helper (one password prompt)
  # that only knows "on" and "off" and lives as long as the program: syncs
  # reuse it. It exits on shutdown_helper, or by itself when we go away (EOF).
  class Isolation
    ANCHOR = "com.apple/merlin"
    REPLY_TIMEOUT = 15

    # $1 = rules, $2 = pfctl path. Reads "on" / "off <token>" / "quit" lines.
    HELPER = <<~'SH'
      rules=$1; pfctl=$2
      echo __READY__
      while IFS= read -r cmd; do
        case "$cmd" in
          on)
            if printf '%s' "$rules" | "$pfctl" -a com.apple/merlin -f - 2>&1 && "$pfctl" -E 2>&1
            then echo __OK__; else echo __FAIL__; fi ;;
          off*)
            tok=${cmd#off}; tok=${tok# }
            if "$pfctl" -a com.apple/merlin -F all 2>&1
            then [ -z "$tok" ] || "$pfctl" -X "$tok" 2>&1; echo __OK__; else echo __FAIL__; fi ;;
          quit) exit 0 ;;
          *) echo "unknown command"; echo __FAIL__ ;;
        esac
      done
    SH

    # sudo / pfctl are injectable so tests can run the real helper script
    # against a fake pfctl, without admin rights.
    def initialize(state_path:, interface: nil, speaker_ip: "192.168.4.1", port: 50_000,
                   subnet: "192.168.4.0/24", sudo: ["sudo"], pfctl: "/sbin/pfctl", out: $stdout)
      @state_path = state_path
      @interface = interface
      @speaker_ip = speaker_ip
      @port = port
      @subnet = subnet
      @sudo = sudo
      @pfctl = pfctl
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

    attr_writer :out # where status lines go (the TUI points it at each sync's log)

    def active? = !@token.nil?
    def leftover? = File.exist?(@state_path)
    def authorized? = !@helper.nil? && @wait&.alive?

    # Interactive: sudo asks for the admin password on the terminal (once),
    # then the helper waits for on/off requests.
    def authorize!
      return true if authorized?

      @helper_in, @helper_out, @wait = Open3.popen2e(*@sudo, "/bin/sh", "-c", HELPER, "merlin-isolation", rules, @pfctl)
      @helper = true
      # sudo may print "Sorry, try again." and re-prompt: wait for the helper.
      said = []
      while (line = @helper_out.gets)
        return true if line.start_with?("__READY__")

        said << line.strip
      end
      shutdown_helper
      raise Error, "admin rights are needed to isolate the speaker (sudo failed#{": #{said.last}" if said.any?})"
    end

    def enable!
      release_leftover
      output = call("on")
      @token = output[/Token\s*:\s*(\d+)/, 1]
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.write(@state_path, JSON.generate(token: @token, interface: interface))
      @out.puts "Traffic filter on: only the transfer can reach the speaker."
      true
    end

    # Turns the filter off; the helper stays up for the next sync (the program
    # calls shutdown_helper when it exits).
    def disable!
      call("off #{@token}")
      @token = nil
      FileUtils.rm_f(@state_path)
      @out.puts "Traffic filter off."
      true
    end

    # A previous run that died left rules/pf enabled: clean them up.
    def release_leftover
      return unless leftover?

      state = JSON.parse(File.read(@state_path)) rescue {}
      @token = state["token"]
      disable!
    end

    def shutdown_helper
      return unless @helper

      @helper_in.puts("quit") rescue nil
      [@helper_in, @helper_out].each { _1.close rescue nil }
      @wait&.join(2)
      @helper = @helper_in = @helper_out = @wait = nil
    end

    private

    def interface
      @interface ||= begin
        out, = Open3.capture2("networksetup", "-listallhardwareports")
        out[/Hardware Port: (?:Wi-Fi|AirPort)\nDevice: (\S+)/, 1] || "en0"
      end
    end

    # Sends one request to the root helper; returns its output.
    def call(cmd)
      raise Error, "not authorized: the traffic filter needs admin rights first" unless authorized?

      @helper_in.puts(cmd)
      @helper_in.flush
      output = +""
      loop do
        raise Error, "traffic filter helper did not answer" unless @helper_out.wait_readable(REPLY_TIMEOUT)

        line = @helper_out.gets or raise Error, "traffic filter helper exited"
        return output if line.start_with?("__OK__")
        raise Error, "pfctl #{cmd.split.first} failed: #{output.strip.lines.last&.strip}" if line.start_with?("__FAIL__")

        output << line
      end
    rescue IOError, SystemCallError => e
      raise Error, "traffic filter helper: #{e.message}"
    end
  end
end
