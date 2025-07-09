# frozen_string_literal: true

require 'test_helper'
require_relative '../lib/cert_monitor/utils'

class UtilsTest < Minitest::Test
  def setup
    @test_pidfile = 'tmp/pids/test_puma.pid'
    FileUtils.mkdir_p(File.dirname(@test_pidfile))
  end

  def teardown
    FileUtils.rm_f(@test_pidfile)
  end

  def test_write_pid_file
    assert CertMonitor::Utils.write_pid_file(@test_pidfile)
    assert File.exist?(@test_pidfile)
    assert_equal Process.pid.to_s, File.read(@test_pidfile).strip
  end

  def test_extract_domains_from_results
    results = {
      remote: [
        { domain: 'example.com', status: :ok },
        { domain: 'test.com', status: :error }
      ],
      local: [
        { domain: 'local.example.com', status: :ok }
      ]
    }

    domains = CertMonitor::Utils.extract_domains_from_results(results)
    assert_equal ['example.com', 'test.com', 'local.example.com'], domains.sort
  end

  def test_domains_reduced
    current = ['example.com', 'test.com']
    previous = ['example.com', 'test.com', 'old.com']

    assert CertMonitor::Utils.domains_reduced?(current, previous)
    refute CertMonitor::Utils.domains_reduced?(previous, current)
  end

  def test_certificates_reduced
    current = {
      remote: [{ domain: 'example.com' }],
      local: [{ domain: 'local.com' }]
    }

    previous = {
      remote: [{ domain: 'example.com' }, { domain: 'old.com' }],
      local: [{ domain: 'local.com' }]
    }

    assert CertMonitor::Utils.certificates_reduced?(current, previous)
    refute CertMonitor::Utils.certificates_reduced?(previous, current)
  end

  def test_calculate_total_certificates
    results = {
      remote: [{ domain: 'example.com' }, { domain: 'test.com' }],
      local: [{ domain: 'local.com' }]
    }

    assert_equal 3, CertMonitor::Utils.calculate_total_certificates(results)
  end

  def test_puma_status
    CertMonitor::Utils.write_pid_file(@test_pidfile)
    status = CertMonitor::Utils.puma_status(@test_pidfile)

    assert status[:pidfile_exists]
    assert_equal Process.pid, status[:pid]
    assert status[:process_running]
  end
end
