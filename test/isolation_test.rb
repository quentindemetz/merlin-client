# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# Runs the real helper script (without sudo) against a fake pfctl that logs
# its arguments, so no real firewall is touched.
class IsolationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "pfctl.log")
    @pfctl = File.join(@dir, "pfctl")
    File.write(@pfctl, <<~SH)
      #!/bin/sh
      echo "$*" >> #{@log}
      case "$*" in
        *"-f -"*) cat >> #{@log}.rules ;;
        "-E") [ -e #{@dir}/fail_E ] && { echo "pfctl: permission denied"; exit 1; }
              echo "No ALTQ support in kernel"; echo "pf enabled"; echo "Token : 1234567890" ;;
      esac
      exit 0
    SH
    File.chmod(0o755, @pfctl)
    @iso = new_isolation
  end

  def teardown
    @iso&.shutdown_helper
    FileUtils.rm_rf(@dir)
  end

  def new_isolation = Merlin::Isolation.new(state_path: File.join(@dir, "isolation.json"), interface: "en0",
                                            sudo: [], pfctl: @pfctl, out: StringIO.new)

  def calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

  def test_rules_only_let_the_transfer_and_dhcp_out_of_the_speaker_subnet
    assert_equal <<~PF, @iso.rules
      pass out quick on en0 proto tcp from 192.168.4.0/24 to 192.168.4.1 port 50000
      pass out quick on en0 proto udp from any port 68 to any port 67
      block out quick on en0 from 192.168.4.0/24 to any
    PF
  end

  # One authorization (one sudo prompt) serves the whole sync: on, then off.
  def test_one_helper_turns_the_filter_on_and_off
    @iso.authorize!
    @iso.enable!
    assert @iso.active?
    assert_equal ["-a com.apple/merlin -f -", "-E"], calls
    assert_equal @iso.rules, File.read("#{@log}.rules")
    assert_equal "1234567890", JSON.parse(File.read(File.join(@dir, "isolation.json")))["token"]

    @iso.disable!
    refute @iso.active?
    refute @iso.leftover?
    refute @iso.authorized?, "the helper exits once the filter is off"
    assert_equal ["-a com.apple/merlin -F all", "-X 1234567890"], calls.last(2)
  end

  def test_leftover_from_a_crashed_run_is_cleaned_before_enabling
    File.write(File.join(@dir, "isolation.json"), JSON.generate(token: "42"))
    @iso.authorize!
    @iso.enable!
    assert_equal ["-a com.apple/merlin -F all", "-X 42", "-a com.apple/merlin -f -", "-E"], calls
  end

  def test_pfctl_failure_is_reported_and_the_helper_stops
    File.write(File.join(@dir, "fail_E"), "")
    @iso.authorize!
    err = assert_raises(Merlin::Error) { @iso.enable! }
    assert_match(/pfctl on failed: pfctl: permission denied/, err.message)
    refute @iso.authorized?
  end

  def test_nothing_runs_without_authorization
    err = assert_raises(Merlin::Error) { @iso.enable! }
    assert_match(/admin rights/, err.message)
    assert_empty calls
  end

  def test_failed_authentication
    iso = Merlin::Isolation.new(state_path: File.join(@dir, "i.json"), interface: "en0", sudo: ["false"],
                                pfctl: @pfctl, out: StringIO.new)
    err = assert_raises(Merlin::Error) { iso.authorize! }
    assert_match(/admin rights are needed/, err.message)
  end
end
