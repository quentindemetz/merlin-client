# frozen_string_literal: true

require "socket"
require "digest"
require_relative "protocol"

module Merlin
  class Error < StandardError; end
  class SpeakerError < Error; end
  class SpeakerTimeout < SpeakerError; end

  # Client for the speaker's TCP control/transfer protocol. The speaker exposes
  # it on its own Wi-Fi access point; join that network first.
  class Speaker
    include Protocol

    DEFAULT_HOST = "192.168.4.1"
    DEFAULT_PORT = 50_000
    CHUNK_SIZE = 100 * 1024 # same chunking as the app when streaming files
    DEFAULT_TIMEOUT = 40

    attr_reader :host, :port

    def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT, logger: nil)
      @host = host
      @port = port
      @logger = logger
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

    def connect(timeout: 5)
      @socket = Socket.tcp(host, port, connect_timeout: timeout)
      @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      self
    rescue SystemCallError, IOError, SocketError => e
      raise SpeakerError, "TCP connect failed to #{host}:#{port} — #{e.message}"
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
    def reset = request(Cmd::RESET, timeout: 10) && true

    # Ask the speaker to (re)build its library from a playlist JSON file that
    # was previously uploaded. Can take a long time on big libraries.
    def update_playlist(filename, timeout: 900)
      check_status(Cmd::UPDATE_PLAYLIST, request(Cmd::UPDATE_PLAYLIST, filename.b, timeout: timeout))
    end

    def update_firmware(filename, timeout: 60)
      check_status(Cmd::UPDATE_FIRMWARE, request(Cmd::UPDATE_FIRMWARE, filename.b, timeout: timeout))
    end

    # --- Files ---------------------------------------------------------------

    # Returns { found:, sha256: (hex or nil) }. With verify: true the speaker
    # hashes the file so it can be compared with a local copy.
    def search_file(filename, verify: true, timeout: 10)
      frame = request(Cmd::SEARCH_FILE, [verify ? 1 : 0].pack("C") + filename.b, timeout: timeout)
      p = frame.payload
      case p.getbyte(0)
      when 0
        name_len = p.getbyte(1)
        sha = p.byteslice(2 + name_len, 32)
        { found: true, sha256: sha && sha.bytesize == 32 && verify ? sha.unpack1("H*") : nil }
      when 1 then { found: false, sha256: nil }
      else raise SpeakerError, "searchFile: #{Protocol.status_name(Cmd::SEARCH_FILE, p.getbyte(0))}"
      end
    end

    # Uploads data under +filename+. Returns :uploaded, or :already_present if
    # the speaker already holds a file with that name and SHA-256.
    def upload(filename, data, timeout: 120, &progress)
      data = data.b
      name = filename.b
      raise ArgumentError, "filename too long" if name.bytesize > 200

      header = [name.bytesize].pack("C") + name + [data.bytesize].pack("V") + Digest::SHA256.digest(data)
      status = request(Cmd::UPLOAD_FILE, header, timeout: 20).payload.getbyte(0)
      return :already_present if status == 1
      raise SpeakerError, "upload #{filename}: #{Protocol.status_name(Cmd::UPLOAD_FILE, status)}" unless status.zero?

      sent = 0
      while sent < data.bytesize
        chunk = data.byteslice(sent, CHUNK_SIZE)
        @socket.write(chunk)
        sent += chunk.bytesize
        progress&.call(sent, data.bytesize)
      end
      status = wait_for(Cmd::UPLOAD_FILE, timeout: timeout).payload.getbyte(0)
      raise SpeakerError, "upload #{filename}: #{Protocol.status_name(Cmd::UPLOAD_FILE, status)}" unless status == 1

      :uploaded
    rescue SystemCallError, IOError => e
      raise SpeakerError, "upload #{filename}: #{e.message}"
    end

    # Upload unless an identical file is already there (what the app does).
    def sync_file(filename, data, &progress)
      remote = search_file(filename, verify: true)
      return :already_present if remote[:found] && remote[:sha256] == Digest::SHA256.hexdigest(data)

      upload(filename, data, &progress)
    end

    # "Command files" are 1-byte files whose name triggers an action on the
    # speaker (e.g. clean_listening.cmd).
    def send_command_file(filename) = upload(filename, "\x00")

    # Downloads a file from the speaker. Some names are virtual and produce
    # data on demand (e.g. get_listening.cmd returns listening statistics).
    def get_file(filename, timeout: 60)
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
      raise SpeakerError, "not connected" unless connected?

      log("-> cmd=#{cmd} #{payload.bytesize}B")
      @socket.write(Protocol.encode(cmd, payload))
      wait_for(cmd, timeout: timeout)
    rescue SystemCallError, IOError => e
      raise SpeakerError, "socket error: #{e.message}"
    end

    private

    def wait_for(cmd, timeout:)
      deadline = monotonic + timeout
      loop do
        while (frame = @decoder.next_frame)
          log("<- cmd=#{frame.cmd} #{frame.payload.bytesize}B")
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
      raise SpeakerTimeout, "timed out waiting for #{what}" if remaining <= 0
      raise SpeakerTimeout, "timed out waiting for #{what}" unless @socket.wait_readable(remaining)

      chunk = @socket.read_nonblock(64 * 1024, exception: false)
      return if chunk == :wait_readable
      raise SpeakerError, "socket closed by speaker" if chunk.nil?

      @decoder << chunk
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
