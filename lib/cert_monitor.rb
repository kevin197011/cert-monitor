# frozen_string_literal: true

# 集中加载所有外部gem依赖
require 'logger'
require 'yaml'
require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'dotenv'
require 'openssl'
require 'socket'
require 'find'
require 'concurrent'
require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'sinatra/base'
require 'rack'
require 'rack/handler/puma'

# 加载核心模块
require_relative 'cert_monitor/version'

module CertMonitor
  class Error < StandardError; end

  # 惰性加载子模块
  autoload :Config, 'cert_monitor/config'
  autoload :Logger, 'cert_monitor/logger'
  autoload :NacosClient, 'cert_monitor/nacos_client'
  autoload :RemoteCertClient, 'cert_monitor/remote_cert_client'
  autoload :Checker, 'cert_monitor/checker'
  autoload :LocalCertClient, 'cert_monitor/local_cert_client'
  autoload :Exporter, 'cert_monitor/exporter'
  autoload :Application, 'cert_monitor/application'
end
