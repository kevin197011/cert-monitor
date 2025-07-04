# frozen_string_literal: true

module CertMonitor
  # Certificate checker coordinator class
  # Coordinates remote and local certificate checking
  class Checker
    def initialize
      @config = Config
      @logger = Logger.create('Checker')
      @remote_cert_client = RemoteCertClient.new
      @local_cert_client = LocalCertClient.new

      @logger.debug 'Checker coordinator initialized with RemoteCertClient and LocalCertClient'
    end

    # Check all certificates (both remote and local)
    # @return [Hash] Combined results from both checkers
    def check_all_certificates
      @logger.info 'Starting comprehensive certificate check...'
      @logger.debug 'Initializing result structure'

      start_time = Time.now
      results = {
        remote: [],
        local: [],
        summary: {
          total_remote: 0,
          successful_remote: 0,
          total_local: 0,
          successful_local: 0
        }
      }

      @logger.debug 'Creating concurrent promises for remote and local checks'

      # 并发执行远程和本地检查
      remote_promise = Concurrent::Promise.execute do
        @logger.debug 'Starting remote certificate check promise'
        @remote_cert_client.check_all_domains
      end

      local_promise = Concurrent::Promise.execute do
        @logger.debug 'Starting local certificate check promise'
        @local_cert_client.scan_all_certs
      end

      # 等待两个检查完成
      begin
        @logger.debug 'Waiting for remote and local certificate checks to complete...'
        results[:remote] = remote_promise.value!
        results[:local] = local_promise.value!

        @logger.debug "Remote check returned #{results[:remote].length} results"
        @logger.debug "Local check returned #{results[:local].length} results"

        # 计算统计信息
        results[:summary][:total_remote] = results[:remote].length
        results[:summary][:successful_remote] = results[:remote].count { |r| r && r[:status] == :ok }
        results[:summary][:total_local] = results[:local].length
        results[:summary][:successful_local] = results[:local].count { |r| r && r[:status] == :ok }

        end_time = Time.now
        duration = (end_time - start_time).round(2)

        @logger.info "Certificate check completed - Remote: #{results[:summary][:successful_remote]}/#{results[:summary][:total_remote]}, Local: #{results[:summary][:successful_local]}/#{results[:summary][:total_local]}"
        @logger.debug "Total comprehensive check duration: #{duration}s"

        # 添加检查统计信息
        results[:summary][:check_duration] = duration
        results[:summary][:check_timestamp] = Time.now.iso8601
      rescue StandardError => e
        @logger.error "Certificate check failed: #{e.message}"
        @logger.debug "Comprehensive check error details: #{e.class} - #{e.message}"
        @logger.debug "Error backtrace: #{e.backtrace.first(5).join(', ')}"

        # 添加错误信息到结果
        results[:error] = {
          message: e.message,
          class: e.class.to_s,
          timestamp: Time.now.iso8601
        }
      end

      @logger.debug "Returning comprehensive check results: #{results[:summary]}"
      results
    end

    # Check only remote domain certificates
    # @return [Array<Hash>] Array of remote certificate check results
    def check_remote_certificates
      @logger.info 'Starting remote certificate check...'
      @logger.debug 'Delegating to RemoteCertClient for remote certificate checking'

      start_time = Time.now
      results = @remote_cert_client.check_all_domains
      duration = (Time.now - start_time).round(2)

      @logger.debug "Remote certificate check completed in #{duration}s with #{results.length} results"
      results
    end

    # Check only local certificates
    # @return [Array<Hash>] Array of local certificate check results
    def check_local_certificates
      @logger.info 'Starting local certificate check...'
      @logger.debug 'Delegating to LocalCertClient for local certificate scanning'

      start_time = Time.now
      results = @local_cert_client.scan_all_certs
      duration = (Time.now - start_time).round(2)

      @logger.debug "Local certificate check completed in #{duration}s with #{results.length} results"
      results
    end

    # Legacy method for backward compatibility
    # @deprecated Use check_remote_certificates instead
    def check_all_domains
      @logger.warn 'check_all_domains is deprecated, use check_remote_certificates instead'
      @logger.debug 'Redirecting deprecated method call to check_remote_certificates'
      check_remote_certificates
    end

    # Legacy method for backward compatibility
    # @deprecated Use check_remote_certificates instead
    def check_domain(domain)
      @logger.warn 'check_domain is deprecated, use RemoteCertClient#check_domain directly'
      @logger.debug "Redirecting deprecated method call to RemoteCertClient#check_domain for domain: #{domain}"
      @remote_cert_client.check_domain(domain)
    end
  end
end
