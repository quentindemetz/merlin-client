# frozen_string_literal: true

require "socket"
require "digest"
require_relative "protocol"

module Merlin
  class Error < StandardError; end
  class SpeakerError < Error; end
  # The link to the speaker is the problem (no answer in time, socket closed,
  # TCP errors) — worth reconnecting and retrying, like the app does.
  class SpeakerLinkError < SpeakerError; end
  class SpeakerTimeout < SpeakerLinkError; end

  # Client for the speaker's TCP control/transfer protocol. The speaker exposes
  # it on its own Wi-Fi access point; join that network first.
  class Speaker
    include Protocol

    DEFAULT_HOST = "192.168.4.1"
    DEFAULT_PORT = 50_000
    CHUNK_SIZE = 100 * 1024 # same chunking as the app when streaming files
    # Live speaker timings (logs): commands answer in ~5-400 ms, data streams at
    # ~800 KB/s. Limits are a comfortable margin above that, not the app's
    # open-ended waits, so a dead link is noticed (and recovered) quickly.
    DEFAULT_TIMEOUT = 5

    # Max wait for the speaker to accept an upload / make progress on a write.
    ACK_TIMEOUT = 5
    # Cap for waits on the speaker (except applying a playlist, below); longer
    # outages are handled by retrying (see Sync::LINK_RETRIES).
    MAX_TIMEOUT = 15

    attr_reader :host, :port

    def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT, logger: nil, ack_timeout: ACK_TIMEOUT)
      @host = host
      @port = port
      @logger = logger
      @ack_timeout = ack_timeout
      @decoder = Protocol::Decoder.new(logger: ->(msg) { log(msg) })
    end

    def self.open(**opts)
      speaker = new(**opts)
      speaker.connect
      return speaker unless block_given?

      begin
        yield speaker
      ensure
        speaker.close
      end
    end

    def connect(timeout: 3)
      # Plain socket, like the app's java.net.Socket (no TCP_NODELAY): every
      # request is a single write anyway, and setsockopt on a connection the
      # speaker resets right after accepting it fails with a confusing EINVAL.
      @socket = Socket.tcp(host, port, connect_timeout: timeout)
      log("connected to #{host}:#{port}")
      self
    rescue SystemCallError, IOError, SocketError => e
      log("connect to #{host}:#{port} failed: #{e.message}")
      raise SpeakerLinkError, "TCP connect failed to #{host}:#{port} — #{e.message}"
    end

    def close
      @socket&.close
    rescue IOError
      nil
    ensure
      @socket = nil
    end

    def connected? = !@socket.nil? && !@socket.closed?

    # --- Simple queries ------------------------------------------------------

    def ping(timeout: 2)
      request(Cmd::PING, timeout: timeout)
      true
    end

    def available_space = u32(request(Cmd::AVAILABLE_SPACE).payload)
    def total_size = u32(request(Cmd::TOTAL_SIZE).payload)

    def firmware_version
      p = request(Cmd::FIRMWARE_VERSION).payload
      "#{p.getbyte(0)}.#{p.getbyte(1)}.#{p.byteslice(2, 2).unpack1('v')}"
    end

    def battery_state
      p = request(Cmd::BATTERY_STATE).payload
      { level: p.getbyte(0), charging: p.getbyte(1) != 0 }
    end

    # The app formats the MAC as six *decimal* octets joined by ":" (and reports
    # it to the backend that way), so keep that format.
    def mac_address
      request(Cmd::MAC_ADDRESS).payload.bytes.first(6).join(":")
    end

    # The speaker clock holds local wall-clock time encoded as if it were UTC.
    def date
      secs = u32(request(Cmd::GET_DATE).payload)
      secs.zero? ? nil : Time.at(secs).utc
    end

    def info
      {
        firmware_version: firmware_version,
        mac_address: mac_address,
        battery: battery_state,
        total_size: total_size,
        available_space: available_space,
        date: date
      }
    end

    # --- Settings ------------------------------------------------------------

    def set_date(time = Time.now)
      check_status(Cmd::SET_DATE, request(Cmd::SET_DATE, [time.to_i + time.utc_offset].pack("V")))
    end

    # Two daily windows during which the speaker may be used, each as
    # [[start_h, start_m], [end_h, end_m]]. The app disables a window by sending
    # 10:00-10:00.
    def set_enabling_hours(window1, window2)
      bytes = [*window1, *window2].flatten
      raise ArgumentError, "expected 8 values" unless bytes.size == 8

      check_status(Cmd::SET_ENABLING_HOURS, request(Cmd::SET_ENABLING_HOURS, bytes.pack("C8")))
    end

    def set_wifi(ssid, password, hidden: false)
      ssid = ssid.b
      password = password.b
      payload = [hidden ? 1 : 0, ssid.bytesize, password.bytesize].pack("C3") + ssid + password
      check_status(Cmd::SET_WIFI, request(Cmd::SET_WIFI, payload))
    end

    def end_synchronization = request(Cmd::END_SYNCHRONIZATION) && true
    def reset = request(Cmd::RESET, timeout: 5) && true

    # Ask the speaker to (re)build its library from a playlist JSON file that
    # was previously uploaded. Can take a long time on big libraries.
    # The speaker rebuilds its whole library here, so it gets much longer than
    # other commands.
    PLAYLIST_TIMEOUT = 120

    def update_playlist(filename, timeout: PLAYLIST_TIMEOUT)
      check_status(Cmd::UPDATE_PLAYLIST, request(Cmd::UPDATE_PLAYLIST, filename.b, timeout: timeout))
    end

    def update_firmware(filename, timeout: 15)
      check_status(Cmd::UPDATE_FIRMWARE, request(Cmd::UPDATE_FIRMWARE, filename.b, timeout: timeout))
    end

    # --- Files ---------------------------------------------------------------

    # Returns { found:, sha256: (hex or nil) }. With verify: true the speaker
    # hashes the file so it can be compared with a local copy.
    def search_file(filename, verify: true, timeout: 5)
      frame = request(Cmd::SEARCH_FILE, [verify ? 1 : 0].pack("C") + filename.b, timeout: timeout)
      p = frame.payload
      case p.getbyte(0)
      when 0
        # Firmware 2.1.16 replies [status][nameLen][name][size u32 LE][sha256],
        # like getFile. The app's code (1.20.5) reads the hash right after the
        # name; accept that layout too in case older firmware sends it.
        name_len = p.getbyte(1)
        rest = p.byteslice(2 + name_len..) || "".b
        size, sha = case rest.bytesize
                    when 36 then [rest.byteslice(0, 4).unpack1("V"), rest.byteslice(4, 32)]
                    when 32 then [nil, rest]
                    else [nil, nil]
                    end
        { found: true, size: size, sha256: sha && verify ? sha.unpack1("H*") : nil, raw: p.unpack1("H*") }
      when 1 then { found: false, sha256: nil }
      else raise SpeakerError, "searchFile: #{Protocol.status_name(Cmd::SEARCH_FILE, p.getbyte(0))}"
      end
    end

    # Uploads data under +filename+. Returns :uploaded, or :already_present if
    # the speaker already holds a file with that name and SHA-256.
    # timeout: for the final acknowledgement once all bytes are sent (the
    # speaker verifies the SHA-256); defaults to a size-based allowance.
    def upload(filename, data, timeout: nil, &progress)
      data = data.b
      name = filename.b
      raise ArgumentError, "filename too long" if name.bytesize > 200

      header = [name.bytesize].pack("C") + name + [data.bytesize].pack("V") + Digest::SHA256.digest(data)
      status = request(Cmd::UPLOAD_FILE, header, timeout: @ack_timeout).payload.getbyte(0)
      return :already_present if status == 1
      raise SpeakerError, "upload #{filename}: #{Protocol.status_name(Cmd::UPLOAD_FILE, status)}" unless status.zero?

      sent = 0
      while sent < data.bytesize
        chunk = data.byteslice(sent, CHUNK_SIZE)
        write_all(chunk, "data of #{filename}")
        sent += chunk.bytesize
        progress&.call(sent, data.bytesize)
      end
      log("   streamed #{filename}: #{data.bytesize} B")
      timeout ||= [@ack_timeout + (data.bytesize / 1_000_000), MAX_TIMEOUT].min # +1 s/MB (observed: 0.14 s for 4.5 MB)
      status = wait_for(Cmd::UPLOAD_FILE, timeout: timeout).payload.getbyte(0)
      raise SpeakerError, "upload #{filename}: #{Protocol.status_name(Cmd::UPLOAD_FILE, status)}" unless status == 1

      :uploaded
    rescue SystemCallError, IOError => e
      log("!! socket error while sending #{filename}: #{e.message}")
      raise SpeakerLinkError, "upload #{filename}: #{link_problem(e)}"
    end

    # Upload unless an identical file is already there (what the app does).
    def sync_file(filename, data, &progress)
      remote = search_file(filename, verify: true)
      local = Digest::SHA256.hexdigest(data)
      same_size = remote[:size].nil? || remote[:size] == data.bytesize
      return :already_present if remote[:found] && remote[:sha256] == local && same_size

      if remote[:found]
        log("   #{filename} differs on the speaker: speaker sha=#{remote[:sha256] || 'none'} size=#{remote[:size] || '?'}, " \
            "local sha=#{local} size=#{data.bytesize} (raw reply #{remote[:raw]})")
      end
      upload(filename, data, &progress)
    end

    # "Command files" are 1-byte files whose name triggers an action on the
    # speaker (e.g. clean_listening.cmd).
    def send_command_file(filename) = upload(filename, "\x00")

    # Downloads a file from the speaker. Some names are virtual and produce
    # data on demand (e.g. get_listening.cmd returns listening statistics).
    def get_file(filename, timeout: 10)
      frame = request(Cmd::GET_FILE, filename.b, timeout: timeout)
      p = frame.payload
      status = p.getbyte(0)
      raise SpeakerError, "getFile #{filename} failed: status=#{status}" unless status.zero?

      name_len = p.getbyte(1)
      size = p.byteslice(2 + name_len, 4).unpack1("V")
      sha = p.byteslice(6 + name_len, 32)
      data = read_raw(size, timeout: timeout)
      raise SpeakerError, "getFile #{filename}: SHA-256 mismatch" unless Digest::SHA256.digest(data) == sha

      data
    end

    # --- Transport -----------------------------------------------------------

    def request(cmd, payload = "".b, timeout: DEFAULT_TIMEOUT)
      raise SpeakerLinkError, "not connected" unless connected?

      log("-> #{cmd_name(cmd)} #{describe_request(cmd, payload)}")
      write_all(Protocol.encode(cmd, payload), cmd_name(cmd))
      wait_for(cmd, timeout: timeout)
    rescue SystemCallError, IOError => e
      log("!! socket error during #{cmd_name(cmd)}: #{e.message}")
      raise SpeakerLinkError, link_problem(e)
    end

    private

    def wait_for(cmd, timeout:)
      started = monotonic
      deadline = started + timeout
      loop do
        while (frame = @decoder.next_frame)
          log("<- #{cmd_name(frame.cmd)} #{describe_response(frame)} [#{((monotonic - started) * 1000).round}ms]")
          return frame if frame.cmd == cmd
          if frame.cmd == Cmd::UNKNOWN
            raise SpeakerError, "speaker rejected cmd #{cmd} (CMD_UNKNOWN, status=#{frame.payload.getbyte(0)})"
          end

          log("ignoring unexpected cmd #{frame.cmd}")
        end
        fill(deadline, "cmd #{cmd}")
      end
    end

    def read_raw(size, timeout:)
      deadline = monotonic + timeout
      out = "".b
      while out.bytesize < size
        out << @decoder.take(size - out.bytesize)
        fill(deadline, "file data") if out.bytesize < size
      end
      out
    end

    def fill(deadline, what)
      remaining = deadline - monotonic
      timed_out!(what) if remaining <= 0 || !@socket.wait_readable(remaining)

      chunk = @socket.read_nonblock(64 * 1024, exception: false)
      return if chunk == :wait_readable

      if chunk.nil?
        log("!! socket closed by speaker while waiting for #{what}")
        raise SpeakerLinkError, "socket closed by speaker"
      end
      @decoder << chunk
    end

    # The speaker drops sessions by resetting the TCP connection (it then keeps
    # resetting new ones for a while, as if its transfer service restarts).
    def link_problem(error)
      case error
      when Errno::ECONNRESET then "the speaker reset the connection"
      when Errno::EPIPE then "the speaker closed the connection"
      else "socket error: #{error.message}"
      end
    end

    def timed_out!(what)
      log("!! timed out waiting for #{what}")
      raise SpeakerTimeout, "timed out waiting for #{what}"
    end

    # Like IO#write but bounded: if the speaker stops reading, a plain blocking
    # write would hang forever once the TCP window is full.
    def write_all(data, what, timeout: @ack_timeout)
      deadline = monotonic + timeout
      until data.empty?
        written = @socket.write_nonblock(data, exception: false)
        if written == :wait_writable
          remaining = deadline - monotonic
          timed_out!("the speaker to accept #{what}") if remaining <= 0 || !@socket.wait_writable(remaining)
          next
        end
        data = data.byteslice(written..)
      end
    end

    CMD_NAMES = Protocol::Cmd.constants.to_h { |c| [Protocol::Cmd.const_get(c), c.to_s.downcase] }.freeze

    def cmd_name(cmd) = CMD_NAMES.fetch(cmd, "cmd#{cmd}")

    # Human-readable request summary for the speaker log; Wi-Fi credentials
    # (cmd 16) are never written.
    def describe_request(cmd, payload)
      case cmd
      when Cmd::UPLOAD_FILE
        n = payload.getbyte(0)
        "#{payload.byteslice(1, n)} (#{payload.byteslice(1 + n, 4).unpack1('V')} B)"
      when Cmd::SEARCH_FILE then "#{payload.byteslice(1..)} verify=#{payload.getbyte(0) == 1}"
      when Cmd::UPDATE_PLAYLIST, Cmd::UPDATE_FIRMWARE, Cmd::GET_FILE then payload.dup.force_encoding("UTF-8").scrub
      when Cmd::SET_WIFI then "[REDACTED]"
      when Cmd::SET_DATE then Time.at(payload.unpack1("V")).utc.strftime("%F %T (local, sent as UTC)")
      when Cmd::SET_ENABLING_HOURS then payload.bytes.each_slice(2).map { format("%02d:%02d", *_1) }.each_slice(2).map { _1.join("-") }.join(", ")
      else payload.empty? ? "" : "#{payload.bytesize} B"
      end
    rescue StandardError
      "#{payload.bytesize} B"
    end

    def describe_response(frame)
      status = frame.payload.getbyte(0)
      if Protocol::STATUSES.key?(frame.cmd) && status
        Protocol.status_name(frame.cmd, status)
      elsif frame.cmd == Cmd::UNKNOWN
        "CMD_UNKNOWN status=#{status}"
      else
        "#{frame.payload.bytesize} B"
      end
    end

    def check_status(cmd, frame)
      status = frame.payload.getbyte(0)
      raise SpeakerError, "#{Protocol.status_name(cmd, status)} (cmd #{cmd})" unless status.zero?

      true
    end

    def u32(payload) = payload.byteslice(0, 4).unpack1("V")
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def log(msg) = @logger&.call(msg)
  end
end
