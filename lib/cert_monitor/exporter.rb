# frozen_string_literal: true

require 'sinatra/base'
require 'prometheus/client'
require 'prometheus/client/formats/text'

module CertMonitor
  class Exporter < Sinatra::Base
    def initialize
      super
      @registry = Prometheus::Client.registry
      @checker = Checker.new

      # Define metrics
      @cert_expire_days = Prometheus::Client::Gauge.new(
        :cert_expire_days,
        docstring: 'Number of days until SSL certificate expires',
        labels: [:domain]
      )
      @cert_status = Prometheus::Client::Gauge.new(
        :cert_status,
        docstring: 'SSL certificate check status (1=valid, 0=invalid)',
        labels: [:domain]
      )

      @registry.register(@cert_expire_days)
      @registry.register(@cert_status)
    end

    get '/metrics' do
      content_type 'text/plain; version=0.0.4'

      # Update metrics
      update_metrics

      # Return all metrics
      Prometheus::Client::Formats::Text.marshal(@registry)
    end

    private

    def update_metrics
      @checker.check_all_domains.each do |result|
        if result[:status] == :ok
          @cert_expire_days.set(result[:expire_days], labels: { domain: result[:domain] })
          @cert_status.set(1, labels: { domain: result[:domain] })
        else
          @cert_status.set(0, labels: { domain: result[:domain] })
        end
      end
    end
  end
end
