# frozen_string_literal: true

require 'sinatra/base'
require 'prometheus/client'
require 'prometheus/client/formats/text'

module CertMonitor
  # Prometheus metrics exporter
  class Exporter < Sinatra::Base
    # 设置 Puma 作为服务器
    set :server, :puma
    # 监听所有地址
    set :bind, '0.0.0.0'
    # 设置环境为生产环境
    set :environment, :production

    # 创建注册表
    prometheus = Prometheus::Client.registry

    # 定义指标
    EXPIRE_DAYS = Prometheus::Client::Gauge.new(:cert_expire_days,
                                                docstring: 'Days until certificate expires',
                                                labels: %i[domain source])
    CERT_STATUS = Prometheus::Client::Gauge.new(:cert_status,
                                                docstring: 'Certificate check status',
                                                labels: %i[domain source])
    CERT_TYPE = Prometheus::Client::Gauge.new(:cert_type,
                                              docstring: 'Certificate type (0: Single Domain, 1: Wildcard)',
                                              labels: %i[domain source])
    SAN_COUNT = Prometheus::Client::Gauge.new(:cert_san_count,
                                              docstring: 'Number of Subject Alternative Names',
                                              labels: %i[domain source])

    # 注册指标
    prometheus.register(EXPIRE_DAYS)
    prometheus.register(CERT_STATUS)
    prometheus.register(CERT_TYPE)
    prometheus.register(SAN_COUNT)

    # 健康检查端点
    get '/health' do
      'OK'
    end

    # 指标导出端点
    get '/metrics' do
      content_type 'text/plain; version=0.0.4'
      Prometheus::Client::Formats::Text.marshal(prometheus)
    end

    # 更新证书状态指标
    def self.update_cert_status(domain, status, source: 'remote')
      CERT_STATUS.set(status ? 1 : 0, labels: { domain: domain, source: source })
    end

    # 更新证书过期天数指标
    def self.update_expire_days(domain, days, source: 'remote')
      EXPIRE_DAYS.set(days, labels: { domain: domain, source: source })
    end

    # 更新证书类型指标
    def self.update_cert_type(domain, is_wildcard, source: 'remote')
      CERT_TYPE.set(is_wildcard ? 1 : 0, labels: { domain: domain, source: source })
    end

    # 更新SAN数量指标
    def self.update_san_count(domain, count, source: 'remote')
      SAN_COUNT.set(count, labels: { domain: domain, source: source })
    end
  end
end
