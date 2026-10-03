# frozen_string_literal: true

module Merlin
  module TUI
    # IO-like sink for Sync's output, safe to read from the UI thread.
    # Understands "\r" (progress lines rewrite themselves).
    class SyncLog
      def initialize
        @lines = [+""]
        @mutex = Mutex.new
      end

      def print(*parts)
        @mutex.synchronize do
          parts.join.scan(/\r|\n|[^\r\n]+/) do |tok|
            case tok
            when "\r" then @lines[-1] = +""
            when "\n" then @lines << +""
            else @lines[-1] << tok
            end
          end
        end
        nil
      end

      def puts(*parts)
        parts = [""] if parts.empty?
        parts.each { |p| print(p.to_s.end_with?("\n") ? p.to_s : "#{p}\n") }
        nil
      end

      def lines
        @mutex.synchronize { @lines.last.empty? ? @lines[0..-2] : @lines.dup }
      end
    end

    # Stands in for Merlin::Wifi inside the TUI: instead of reading stdin it
    # waits until the user confirms on the sync screen.
    class TuiWifi
      # waiting: speaker AP details while we wait for the user to join it.
      # reconnecting: true while we wait for the user to get back online.
      attr_reader :waiting, :reconnecting

      def initialize(auto:, log:, online: -> { true })
        @queue = Queue.new
        @online = online
        @real = Wifi.new(auto: true, out: log) if auto
      end

      def join_speaker(ssid, password)
        return @real.join_speaker(ssid, password) if @real

        @waiting = { ssid: ssid, password: password }
        @queue.pop
      ensure
        @waiting = nil
      end

      # Returns once the Merlin API is reachable again (polled), or when the
      # user presses Enter.
      def restore
        return @real.restore if @real

        @reconnecting = true
        until @online.call
          return :skip if @queue.pop(timeout: 3)
        end
        :online
      ensure
        @reconnecting = false
      end

      def confirm
        @queue << true if @waiting || @reconnecting
      end

      def rejoin_speaker = @real&.rejoin_speaker
    end

    # One synchronisation running in a background thread.
    #
    # The session is "finished" as soon as the speaker part is over (its
    # outcome is known); getting back online and reporting to Merlin happens
    # afterwards, still in the background thread ("reporting?").
    class SyncSession
      attr_reader :log, :wifi, :state, :error

      attr_reader :isolation

      def initialize(app, auto_wifi:, isolate: true)
        @log = SyncLog.new
        @wifi = TuiWifi.new(auto: auto_wifi, log: @log, online: -> { app.backend.reachable? })
        @isolation = app.new_isolation(out: @log) if isolate
        opts = { out: @log, wifi: @wifi, on_transfer_end: ->(report) { @state = outcome(report) } }
        opts[:isolation] = @isolation if @isolation
        @sync = app.new_sync(**opts)
        @state = :idle
      end

      def start
        @state = :running
        @thread = Thread.new do
          @sync.run
          @state = :done if running?
        rescue Interrupt
          @log.puts "Aborted."
          @state = :aborted if running?
        rescue StandardError => e
          @error = e
          @log.puts "Error: #{e.message}"
          @state = :failed if running?
        end
        @thread.report_on_exception = false
        self
      end

      def running? = @state == :running
      def finished? = %i[done failed aborted].include?(@state)
      def reporting? = finished? && @thread&.alive?
      def abort! = @thread&.raise(Interrupt)
      def join(timeout = nil) = @thread&.join(timeout)

      # Leaving the app: stop waiting for internet (the report is then saved
      # and sent at the next sync) and let the thread finish.
      def shutdown
        return unless @thread&.alive?

        @wifi.confirm
        @thread.join(15)
      end

      private

      def outcome(report)
        return :done if report[:status] == "SUCCESS"

        report[:status_code].to_s.start_with?("800") ? :aborted : :failed
      end
    end

    module Screens
      class SyncScreen < ListScreen
        def initialize(app)
          super
          @auto_wifi = false
          @isolate = true
        end

        attr_reader :session

        def title = "Sync"
        def busy? = @session&.running? || false

        def hints
          return [%w[↑↓ move], %w[enter select], %w[esc back]] unless @session
          return [["enter", "don't wait (report sent at next sync)"], %w[esc back]] if reconnect_banner?
          return [%w[esc back]] if @session.finished?
          return [["enter", "I'm on the speaker Wi-Fi"], %w[ctrl-c abort]] if @session.wifi.waiting

          [%w[ctrl-c abort]]
        end

        def intro
          speaker = app.current_speaker&.dig("speaker_name") || "your speaker"
          [
            "Transfer the basket#{" (#{app.basket_count} pending)" if app.basket_count} and your account's content to #{speaker}.",
            "Files are downloaded first while you're online; then you'll join the speaker's Wi-Fi " \
            "(switch it on and press its Wifi / Transfert button)."
          ]
        end

        def build_rows
          [Row.item("Start transfer", :start),
           Row.item("Switch Wi-Fi automatically (macOS networksetup): #{@auto_wifi ? 'ON' : 'off'}", :auto),
           Row.item("Block this Mac's other traffic (admin password): " \
                    "#{@isolate ? 'ON' : 'off (speaker may crash)'}", :isolate)]
        end

        def handle(event)
          return super unless @session

          if reconnect_banner? && event == :enter
            @session.wifi.confirm # stop waiting for internet
          elsif @session.finished?
            # Leaving is fine: a pending report keeps going in the background.
            app.pop if %i[esc left enter backspace].include?(event.to_sym)
          elsif event == :ctrl_c || event == :esc
            @session.abort!
            app.notify("Aborting…")
          elsif event == :enter
            @session.wifi.confirm
          end
        end

        def activate(row)
          case row.value
          when :auto
            @auto_wifi = !@auto_wifi
            @rows = nil
          when :isolate
            @isolate = !@isolate
            @rows = nil
          when :start
            session = SyncSession.new(app, auto_wifi: @auto_wifi, isolate: @isolate)
            return unless authorize(session)

            @session = session.start
            app.active_sync = @session
          end
        end

        def render(frame, area)
          return super unless @session

          log_area = area
          if (title, text = banner)
            box, log_area = tui.layout_split(area, direction: :vertical,
                                                   constraints: [tui.constraint_length(6), tui.constraint_fill(1)])
            frame.render_widget(tui.paragraph(text: text.join("\n"), style: app.style(fg: :yellow),
                                              block: tui.block(title: " #{title} ", borders: [:all],
                                                               border_style: app.style(fg: :yellow))), box)
          end
          lines = @session.log.lines
          lines += ["", result_line] if @session.finished?
          visible = [log_area.height - 2, 1].max
          frame.render_widget(tui.paragraph(text: lines.last(visible).join("\n"),
                                            block: tui.block(title: " Transfer — #{state_label} ", borders: [:all],
                                                             border_style: app.style(fg: border_color))), log_area)
        end

        private

        # sudo asks for the admin password on the real terminal, so step out of
        # the full-screen UI for it (once, before downloads start).
        def authorize(session)
          return true unless session.isolation

          app.suspend do
            puts "\nThe speaker crashes when this Mac's other traffic reaches it, so a temporary"
            puts "network filter is applied during the transfer. macOS needs your admin password:"
            session.isolation.authorize!
          end
          true
        rescue Error => e
          app.error("#{e.message} — turn the traffic filter off to sync without it")
          false
        end

        # Only once the transfer has finished (its result is on screen), never
        # while the sync is still underway.
        def reconnect_banner? = @session&.finished? && @session.wifi.reconnecting

        def state_label
          @session.reporting? ? "#{@session.state} · reporting to Merlin" : @session.state.to_s
        end

        def banner
          if (w = @session.wifi.waiting)
            ["Join the speaker Wi-Fi",
             ["Switch the speaker on and press its Wifi / Transfert button,",
              "then join its Wi-Fi network: #{w[:ssid] || 'MERLIN…'}#{"   password: #{w[:password]}" if w[:password]}",
              "", "Press Enter once your laptop is connected."]]
          elsif reconnect_banner?
            ["Back to your usual Wi-Fi",
             ["Done with the speaker. Reconnect this Mac to your usual Wi-Fi network.",
              "The report is sent to Merlin automatically as soon as it's reachable.",
              "", "Press Enter to stop waiting (the report will then be sent at the next sync)."]]
          end
        end

        def result_line
          case @session.state
          when :done then "✔ Transfer complete. Press Esc to go back."
          when :aborted then "Transfer aborted. Press Esc to go back."
          else "✘ Transfer failed. API call details: #{app.config.log_dir}/. Press Esc to go back."
          end
        end

        def border_color
          { done: :green, failed: :red, aborted: :red }.fetch(@session.state, :cyan)
        end
      end
    end
  end
end
