# Puma 重启功能

cert-monitor 现在支持在检测到域名或证书减少时自动重启 Puma 服务器。

## 功能概述

当证书检查发现以下情况时，系统会自动触发 Puma 重启：

1. **域名减少**：检测到的域名数量比上次检查时减少
2. **证书减少**：远程或本地证书总数比上次检查时减少

## 工作原理

### 1. PID 文件管理

应用启动时会自动创建 PID 文件（默认位置：`tmp/pids/puma.pid`），用于标识当前 Puma 进程。

### 2. 检查逻辑

每次证书检查完成后，系统会：

1. 提取当前检查结果中的域名列表
2. 与上次检查结果进行对比
3. 如果发现减少，则发送 `USR2` 信号给 Puma 主进程

### 3. 优雅重启

使用 `USR2` 信号触发 Puma 的优雅重启，确保：
- 现有连接不会被中断
- 新进程启动后再关闭旧进程
- 零停机时间重启

## 配置

### PID 文件路径

默认 PID 文件路径为 `tmp/pids/puma.pid`，可以通过以下方式自定义：

```ruby
# 在应用中使用自定义 PID 文件路径
CertMonitor::Utils.check_and_restart_if_reduced(
  current_results,
  previous_results,
  'custom/path/puma.pid'
)
```

### Docker 环境

在 Docker 环境中，建议在应用启动时显式写入 PID 文件：

```ruby
# 在应用启动脚本中
CertMonitor::Utils.write_pid_file('tmp/pids/puma.pid')
```

## API 参考

### CertMonitor::Utils

#### `write_pid_file(pidfile = 'tmp/pids/puma.pid')`

写入当前进程 PID 到指定文件。

```ruby
CertMonitor::Utils.write_pid_file('tmp/pids/puma.pid')
# => true/false
```

#### `restart_puma(pidfile = 'tmp/pids/puma.pid')`

重启 Puma 进程。

```ruby
CertMonitor::Utils.restart_puma('tmp/pids/puma.pid')
# => true/false
```

#### `check_and_restart_if_reduced(current_results, previous_results, pidfile = 'tmp/pids/puma.pid')`

检查是否需要重启，并在需要时执行重启。

```ruby
CertMonitor::Utils.check_and_restart_if_reduced(
  current_results,
  previous_results
)
# => true/false (是否执行了重启)
```

#### `extract_domains_from_results(results)`

从证书检查结果中提取域名列表。

```ruby
domains = CertMonitor::Utils.extract_domains_from_results(results)
# => ['example.com', 'test.com', ...]
```

#### `puma_status(pidfile = 'tmp/pids/puma.pid')`

获取 Puma 进程状态信息。

```ruby
status = CertMonitor::Utils.puma_status
# => {
#      pidfile_exists: true,
#      pid: 12345,
#      process_running: true
#    }
```

## 日志输出

系统会记录详细的重启相关信息：

```
[INFO] Domain reduction detected. Current: 5, Previous: 7
[INFO] Reduced domains: old-domain.com, removed-domain.com
[INFO] Attempting Puma restart - Reason: Domain reduction detected
[DEBUG] Puma status - PID file exists: true, PID: 12345, Process running: true
[INFO] Puma restart triggered successfully
```

## 错误处理

系统包含完善的错误处理机制：

- PID 文件不存在时的警告
- 无效 PID 的处理
- 进程不存在时的处理
- 重启失败时的错误记录

## 测试

运行测试以验证功能：

```bash
bundle exec ruby test/utils_test.rb
```

## 注意事项

1. **权限要求**：确保应用有权限向 Puma 进程发送信号
2. **PID 文件路径**：确保 PID 文件路径可写且正确
3. **Docker 环境**：在容器环境中需要确保 PID 文件正确创建
4. **日志级别**：建议设置适当的日志级别以监控重启活动

## 故障排除

### 重启不工作

1. 检查 PID 文件是否存在：
   ```ruby
   status = CertMonitor::Utils.puma_status
   puts status
   ```

2. 检查进程是否运行：
   ```ruby
   Process.kill(0, pid) rescue puts "Process not running"
   ```

3. 检查权限：
   ```bash
   ls -la tmp/pids/puma.pid
   ```

### 频繁重启

如果发现频繁重启，可以：

1. 检查域名配置是否正确
2. 验证证书检查结果的准确性
3. 调整检查间隔时间