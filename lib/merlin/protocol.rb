# frozen_string_literal: true

module Merlin
  # Wire format of the speaker's TCP protocol (192.168.4.1:50000).
  #
  # Every frame is:
  #
  #   [len:u8] [cmd:u8] [payload...] [crc32:u32 LE]
  #
  # where len = payload.bytesize + 5 (i.e. the frame is len + 1 bytes long) and
  # crc32 is CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, no
  # final xor) computed over cmd + payload.
  #
  # File contents (uploads and downloads) are NOT framed: after the speaker
  # accepts a transfer, raw bytes are streamed on the same socket.
  module Protocol
    module Cmd
      UPLOAD_FILE        = 1
      PING               = 2
      AVAILABLE_SPACE    = 3
      TOTAL_SIZE         = 4
      FIRMWARE_VERSION   = 5
      UPDATE_PLAYLIST    = 6
      UPDATE_FIRMWARE    = 7
      SET_DATE           = 8
      END_SYNCHRONIZATION = 9
      RESET              = 10
      GET_FILE           = 13
      BATTERY_STATE      = 14
      SET_WIFI           = 16
      GET_DATE           = 27
      SET_ENABLING_HOURS = 29
      MAC_ADDRESS        = 30
      SEARCH_FILE        = 31
      UNKNOWN            = 0xFF
    end

    # Status codes, keyed by the command whose response carries them.
    STATUSES = {
      Cmd::UPLOAD_FILE => %w[
        SUCCESS SHA256_VALID NOT_ENOUGH_SPACE FILENAME_TOO_LARGE SHA256_INVALID
        BAD_LENGTH_CMD TIMEOUT FAIL_CREATE_FILE
      ],
      Cmd::UPDATE_PLAYLIST => %w[
        SUCCESS BAD_FILENAME_LEN BAD_EXTENSION_FILE FILE_NOT_FOUND FAIL_MINIFIER
        FAIL_OPEN_JSON FAIL_OPEN_BINARY ROOT_ELEMENT_IS_NOT_ARRAY
        BAD_ROOT_CHILD_QUANTITY MISSING_FIELD BAD_UUID_FIELD UUID_TOO_LARGE
        BAD_TITLE_FIELD TITLE_TOO_LARGE FAIL_ADD_ELEMENT FAIL_RENAME_BIN_FILE
        INVALID_TYPE_IN_BINARY_FILE IMAGE_NOT_FOUND MUSIC_NOT_FOUND
        FAVORITES_NOT_FOUND TOO_MANY_FAVORITES FAIL_CREATE_FAV_FILE
        FAIL_OPEN_FAV_FILE BAD_FAV_FORMAT
      ],
      Cmd::UPDATE_FIRMWARE => %w[
        SUCCESS BAD_FILENAME_LEN BAD_EXTENSION_FILE FILE_NOT_FOUND
        PARTITION_UPDATE_NOT_FOUND FAIL_OPEN_FILE FAIL_ERASE_PARTITION
        FAIL_WRITE_FIRMWARE FAIL_ENABLE_BOOT_PARTITION BAD_FILE_FORMAT BAD_SHA256
      ],
      Cmd::SET_DATE => %w[SUCCESS BAD_ARG_LEN],
      Cmd::SET_WIFI => %w[SUCCESS BAD_CMD_LEN BAD_HIDDEN_VALUE BAD_SSID_LEN BAD_PASSWORD_LEN],
      Cmd::SET_ENABLING_HOURS => %w[SUCCESS BAD_CMD_LEN BAD_VALUE],
      Cmd::SEARCH_FILE => %w[SUCCESS FILE_NOT_FOUND FAIL_OPEN]
    }.freeze

    def self.status_name(cmd, code)
      STATUSES.fetch(cmd, []).fetch(code, nil) || "UNKNOWN(#{code})"
    end

    Frame = Struct.new(:cmd, :payload)

    def self.crc32_mpeg2(bytes)
      crc = 0xFFFFFFFF
      bytes.each_byte do |b|
        crc ^= b << 24
        8.times { crc = crc.anybits?(0x80000000) ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1) }
        crc &= 0xFFFFFFFF
      end
      crc
    end

    def self.encode(cmd, payload = "".b)
      payload = payload.b
      raise ArgumentError, "payload too large for one frame (#{payload.bytesize} bytes)" if payload.bytesize > 250

      body = [cmd].pack("C") + payload
      [payload.bytesize + 5].pack("C") + body + [crc32_mpeg2(body)].pack("V")
    end

    # Incremental decoder mirroring the app's read loop: bytes are appended with
    # #<<, complete frames are pulled with #next_frame, and raw (unframed) bytes
    # can be pulled with #take during file downloads.
    class Decoder
      def initialize(logger: nil)
        @buf = "".b
        @logger = logger
      end

      def <<(data)
        @buf << data.b
        self
      end

      def bytesize = @buf.bytesize

      def take(max)
        @buf.slice!(0, max)
      end

      def next_frame
        loop do
          return nil if @buf.empty?

          len = @buf.getbyte(0)
          if len < 5
            @buf.slice!(0, 1) # resync, same as the app
            next
          end
          return nil if @buf.bytesize < len + 1

          raw = @buf.slice!(0, len + 1)
          body = raw.byteslice(1, len - 4)
          expected = raw.byteslice(len - 3, 4).unpack1("V")
          actual = Protocol.crc32_mpeg2(body)
          if actual != expected
            @logger&.call(format("bad CRC %08x != %08x, dropping frame", actual, expected))
            next
          end
          return Frame.new(body.getbyte(0), body.byteslice(1..))
        end
      end
    end
  end
end
