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
    EXPIRE_DAYS = Prometheus::Client::Gauge.new(:cert_expire_days, docstring: 'Days until certificate expires',
                                                                   labels: [:domain])
    CERT_STATUS = Prometheus::Client::Gauge.new(:cert_status, docstring: 'Certificate check status', labels: [:domain])

    # 注册指标
    prometheus.register(EXPIRE_DAYS)
    prometheus.register(CERT_STATUS)

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
    def self.update_cert_status(domain, status)
      CERT_STATUS.set(status ? 1 : 0, labels: { domain: domain })
    end

    # 更新证书过期天数指标
    def self.update_expire_days(domain, days)
      EXPIRE_DAYS.set(days, labels: { domain: domain })
    end
  end
end
