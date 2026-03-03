# rosbag2 `--max-cache-duration` 功能修改文档

## 概述

**Commit**: `aa83b66a83ba656f30f6e8f2ac2807ea54c5832d`  
**作者**: Michael Orlov  
**日期**: 2026-01-22  
**功能**: 为 Recorder 添加 `--max-cache-duration` 选项，实现基于时间限制的 Snapshot 功能

---

## 功能描述

此 commit 为 rosbag2 的 snapshot 模式添加了**时间限制缓存**功能。除了原有的基于大小的缓存限制 (`--max-cache-size`)，现在还可以设置基于时间的缓存限制 (`--max-cache-duration`)。

### 核心特性

1. **双重限制**: 缓存可以同时受大小和时间限制
2. **灵活配置**:
   - 仅时间限制: `--max-cache-size 0 --max-cache-duration 30`
   - 仅大小限制: `--max-cache-size 100000000 --max-cache-duration 0`
   - 双重限制: `--max-cache-size 50000000 --max-cache-duration 10`
3. **Snapshot 模式支持**: 在 snapshot 模式下，至少需要一个限制条件（大小或时间）

---

## 修改的文件列表

| 文件路径 | 修改类型 | 说明 |
|---------|---------|------|
| `README.md` | 文档更新 | 添加 `--max-cache-duration` 使用说明 |
| `ros2bag/ros2bag/verb/record.py` | 功能添加 | 添加 CLI 参数和验证逻辑 |
| `rosbag2_cpp/CMakeLists.txt` | 构建配置 | 更新测试链接库 |
| `rosbag2_cpp/include/rosbag2_cpp/cache/circular_message_cache.hpp` | API 修改 | 构造函数添加 `max_buffer_duration` 参数 |
| `rosbag2_cpp/include/rosbag2_cpp/cache/message_cache.hpp` | API 修改 | 构造函数添加 `max_cache_duration` 参数 |
| `rosbag2_cpp/include/rosbag2_cpp/cache/message_cache_buffer.hpp` | API 修改 | 添加时间限制相关成员和方法 |
| `rosbag2_cpp/include/rosbag2_cpp/cache/message_cache_circular_buffer.hpp` | API 修改 | 添加时间限制相关成员和方法 |
| `rosbag2_cpp/src/rosbag2_cpp/cache/circular_message_cache.cpp` | 实现修改 | 传递时间限制参数给缓冲区 |
| `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache.cpp` | 实现修改 | 传递时间限制参数，添加空消息检查 |
| `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_buffer.cpp` | 实现修改 | 实现时间限制逻辑 |
| `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_circular_buffer.cpp` | 实现修改 | 实现循环缓冲区的时间限制逻辑 |
| `rosbag2_cpp/src/rosbag2_cpp/reindexer.cpp` | 代码优化 | 简化 StorageOptions 复制 |
| `rosbag2_cpp/src/rosbag2_cpp/writers/sequential_writer.cpp` | 逻辑修改 | 更新缓存启用条件和创建逻辑 |
| `rosbag2_cpp/test/rosbag2_cpp/test_circular_message_cache.cpp` | 测试添加 | 添加时间限制相关测试 |
| `rosbag2_cpp/test/rosbag2_cpp/test_message_cache.cpp` | 测试添加 | 添加时间限制相关测试 |
| `rosbag2_py/rosbag2_py/_storage.pyi` | Python 绑定 | 添加 `max_cache_duration` 字段 |
| `rosbag2_py/src/rosbag2_py/_storage.cpp` | Python 绑定 | 添加 `max_cache_duration` 绑定 |
| `rosbag2_storage/include/rosbag2_storage/storage_options.hpp` | 数据结构 | 添加 `max_cache_duration` 字段 |
| `rosbag2_storage/src/rosbag2_storage/storage_options.cpp` | 实现 | 添加字段初始化 |
| `rosbag2_storage/test/rosbag2_storage/test_storage_options.cpp` | 测试 | 更新测试 |
| `rosbag2_storage_default_plugins/test/rosbag2_storage_default_plugins/storage_test_fixture.hpp` | 测试 | 更新测试夹具 |
| `rosbag2_storage_default_plugins/test/rosbag2_storage_default_plugins/test_sqlite_storage.cpp` | 测试 | 更新测试 |
| `rosbag2_tests/test/rosbag2_tests/test_rosbag2_record_end_to_end.cpp` | 集成测试 | 添加端到端测试 |
| `rosbag2_transport/src/rosbag2_transport/config_options_from_node_params.cpp` | 配置解析 | 添加参数解析 |
| `rosbag2_transport/test/resources/player_node_params.yaml` | 配置示例 | 更新示例配置 |
| `rosbag2_transport/test/resources/recorder_node_params.yaml` | 配置示例 | 更新示例配置 |
| `rosbag2_transport/test/rosbag2_transport/test_composable_player.cpp` | 测试 | 更新测试 |
| `rosbag2_transport/test/rosbag2_transport/test_composable_recorder.cpp` | 测试 | 更新测试 |

---

## 详细修改说明

### 1. StorageOptions 数据结构 (`rosbag2_storage`)

**文件**: `rosbag2_storage/include/rosbag2_storage/storage_options.hpp`

在 `StorageOptions` 结构体中添加新字段：

```cpp
// 在 max_cache_size 之后添加
uint32_t max_cache_duration = 0;  // 单位：秒
```

**类型选择理由**:
- 使用 `uint32_t` 而非 `rclcpp::Duration`
- 实际应用中不需要亚秒级精度
- 避免对 rclcpp 层的依赖
- 简化操作

---

### 2. CLI 参数添加 (`ros2bag`)

**文件**: `ros2bag/ros2bag/verb/record.py`

添加新的命令行参数：

```python
parser.add_argument(
    '--max-cache-duration', type=int, default=0,
    help='Maximum cache duration in seconds.\n'
         'Default: %(default)d, indicates that buffering will be limited by the'
         ' --max-cache-size parameter only. If the value is more than 0, the cache buffer'
         ' will be limited by both the series of messages duration and the maximum cache size'
         ' parameter.\n'
         'To override the upper bound by total messages size, the --max-cache-size parameter'
         ' can be set to 0.')
```

添加参数验证：

```python
# 验证非负
if args.max_cache_size < 0:
    return print_error('max_cache_size must be a non-negative integer.')

if args.max_cache_duration < 0:
    return print_error('max_cache_duration must be a non-negative integer.')

# 验证上限 (uint32_t max)
if args.max_cache_size > 4294967295:
    return print_error('max_cache_size must not exceed 4294967295 bytes')

if args.max_cache_duration > 4294967295:
    return print_error('max_cache_duration must not exceed 4294967295 seconds')

# Snapshot 模式至少需要一个限制
if args.snapshot_mode and args.max_cache_duration == 0 and args.max_cache_size == 0:
    return print_error('In snapshot mode, either the max_cache_duration or max_cache_size'
                       ' shall not be set to zero.')
```

---

### 3. 缓存缓冲区实现 (`rosbag2_cpp`)

#### 3.1 MessageCacheBuffer (普通缓存)

**文件**: `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_buffer.cpp`

**构造函数修改**:
```cpp
MessageCacheBuffer::MessageCacheBuffer(size_t max_cache_size, uint32_t max_cache_duration)
: max_bytes_size_(max_cache_size), 
  max_cache_duration_ns_(RCUTILS_S_TO_NS(max_cache_duration))
{
  // 至少需要一个限制条件
  if (max_bytes_size_ == 0 && max_cache_duration_ns_ == 0) {
    throw std::invalid_argument("Invalid arguments for the MessageCacheBuffer. "
                                "Both max_bytes_size and max_cache_duration are zero.");
  }
  // ...
}
```

**push() 方法修改**:
```cpp
bool MessageCacheBuffer::push(CacheBufferInterface::buffer_element_t msg)
{
  // 空消息检查
  if (!msg || !msg->serialized_data) {
    ROSBAG2_CPP_LOG_ERROR("Attempted to push null message into cache buffer. Dropping message!");
    return false;
  }

  // 计算预期缓冲区持续时间
  rcutils_time_point_value_t prospected_buffer_duration = 0;
  if (max_cache_duration_ns_ > 0 && buffer_.size() > 0) {
    prospected_buffer_duration = msg->recv_timestamp - buffer_.front()->recv_timestamp;
    if (prospected_buffer_duration < 0) {
      // 时间戳乱序，丢弃消息
      return false;
    }
  }

  // 检查限制条件
  if (!drop_messages_) {
    // 时间限制检查
    if (max_cache_duration_ns_ > 0) {
      if (static_cast<uint64_t>(prospected_buffer_duration) > max_cache_duration_ns_) {
        drop_messages_ = true;
      }
    }

    // 大小限制检查（允许至少一条消息）
    if (max_bytes_size_ > 0 && !buffer_.empty()) {
      if (buffer_bytes_size_ + msg->serialized_data->buffer_length > max_bytes_size_) {
        drop_messages_ = true;
      }
    }

    if (!drop_messages_) {
      buffer_bytes_size_ += msg->serialized_data->buffer_length;
      buffer_.push_back(msg);
      pushed = true;
    }
  }
  return pushed;
}
```

#### 3.2 MessageCacheCircularBuffer (循环缓存 - Snapshot 模式)

**文件**: `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_circular_buffer.cpp`

循环缓存的行为不同：当超出限制时，**移除最旧的消息**而不是丢弃新消息。

```cpp
bool MessageCacheCircularBuffer::push(CacheBufferInterface::buffer_element_t msg)
{
  // 空消息检查
  if (!msg || !msg->serialized_data) {
    return false;
  }

  // 单条消息超过大小限制时丢弃（仅当大小限制启用时）
  if (max_bytes_size_ > 0 && 
      msg->serialized_data->buffer_length > max_bytes_size_) {
    ROSBAG2_CPP_LOG_WARN("Last message exceeds snapshot buffer size. Dropping message!");
    return false;
  }

  // 移除旧消息直到有空间（大小限制）
  while (max_bytes_size_ > 0 &&
    buffer_bytes_size_ > (max_bytes_size_ - msg->serialized_data->buffer_length))
  {
    buffer_bytes_size_ -= buffer_.front()->serialized_data->buffer_length;
    buffer_.pop_front();
  }

  // 移除旧消息直到满足时间限制
  if (max_cache_duration_ns_ > 0 && buffer_.size() > 0) {
    auto prospected_buffer_duration = msg->recv_timestamp - buffer_.front()->recv_timestamp;
    
    // 处理时间戳乱序
    if (prospected_buffer_duration < 0) {
      ROSBAG2_CPP_LOG_ERROR_STREAM("Can't calculate prospected circular cache buffer duration...");
      return false;
    }

    // 循环移除超时的旧消息
    while (buffer_.size() > 0 && 
           static_cast<uint64_t>(prospected_buffer_duration) > max_cache_duration_ns_) {
      buffer_bytes_size_ -= buffer_.front()->serialized_data->buffer_length;
      buffer_.pop_front();
      prospected_buffer_duration = msg->recv_timestamp - buffer_.front()->recv_timestamp;
    }
  }

  // 添加新消息
  buffer_bytes_size_ += msg->serialized_data->buffer_length;
  buffer_.push_back(msg);

  return true;
}
```

---

### 4. 缓存类构造函数修改

**文件**: 
- `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache.cpp`
- `rosbag2_cpp/src/rosbag2_cpp/cache/circular_message_cache.cpp`

```cpp
// MessageCache
MessageCache::MessageCache(size_t max_buffer_size, uint32_t max_buffer_duration)
{
  producer_buffer_ = std::make_shared<MessageCacheBuffer>(max_buffer_size, max_buffer_duration);
  consumer_buffer_ = std::make_shared<MessageCacheBuffer>(max_buffer_size, max_buffer_duration);
}

// CircularMessageCache
CircularMessageCache::CircularMessageCache(size_t max_buffer_size, uint32_t max_buffer_duration)
{
  producer_buffer_ = std::make_shared<MessageCacheCircularBuffer>(max_buffer_size, max_buffer_duration);
  consumer_buffer_ = std::make_shared<MessageCacheCircularBuffer>(max_buffer_size, max_buffer_duration);
}
```

---

### 5. SequentialWriter 修改

**文件**: `rosbag2_cpp/src/rosbag2_cpp/writers/sequential_writer.cpp`

更新缓存启用条件：

```cpp
// 原逻辑
use_cache_ = storage_options.max_cache_size > 0u;

// 新逻辑
use_cache_ = storage_options.max_cache_size > 0u || storage_options.max_cache_duration > 0u;

// Snapshot 模式验证
if (storage_options.snapshot_mode && !use_cache_) {
  throw std::runtime_error(
    "Either the max cache size or the maximum cache duration must be greater than 0"
    " when snapshot mode is enabled");
}

// 创建缓存时传递时间参数
if (storage_options.snapshot_mode) {
  message_cache_ = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    storage_options.max_cache_size, storage_options.max_cache_duration);
} else {
  message_cache_ = std::make_shared<rosbag2_cpp::cache::MessageCache>(
    storage_options.max_cache_size, storage_options.max_cache_duration);
}
```

---

### 6. Python 绑定

**文件**: `rosbag2_py/src/rosbag2_py/_storage.cpp`

```cpp
// 添加 max_cache_duration 字段绑定
py::class_<rosbag2_storage::StorageOptions>(m, "StorageOptions")
  // ... 其他字段
  .def_readwrite("max_cache_size", &rosbag2_storage::StorageOptions::max_cache_size)
  .def_readwrite("max_cache_duration", &rosbag2_storage::StorageOptions::max_cache_duration)
  // ...
```

---

### 7. 参数文件配置

**文件**: `rosbag2_transport/test/resources/recorder_node_params.yaml`

```yaml
rosbag2_recorder:
  ros__parameters:
    # ... 其他参数
    max_cache_size: 100000000
    max_cache_duration: 10  # 新增
    snapshot_mode: false
```

---

## 测试用例

### 1. CircularMessageCache 测试

**文件**: `rosbag2_cpp/test/rosbag2_cpp/test_circular_message_cache.cpp`

新增测试：

| 测试名称 | 说明 |
|---------|------|
| `constructor_throws_if_both_limits_are_zero` | 验证两个限制都为零时抛出异常 |
| `time_only_buffer_drops_old_messages_by_duration` | 仅时间限制，验证旧消息被移除 |
| `size_only_buffer_drops_old_messages_by_size` | 仅大小限制，验证旧消息被移除 |
| `time_and_size_buffer_respects_both_limits` | 双重限制，验证同时满足 |
| `rejects_message_exceeding_size_limit` | 单条消息超过大小限制时拒绝 |
| `handles_out_of_order_timestamps_gracefully` | 处理乱序时间戳 |

### 2. MessageCache 测试

**文件**: `rosbag2_cpp/test/rosbag2_cpp/test_message_cache.cpp`

新增测试：

| 测试名称 | 说明 |
|---------|------|
| `message_cache_rejects_null_message` | 拒绝空消息 |
| `constructor_throws_if_both_limits_are_zero` | 验证两个限制都为零时抛出异常 |
| `message_cache_buffer_time_only_limits_by_duration` | 仅时间限制测试 |

---

## 使用示例

### 1. 普通录制 + 时间限制缓存

```bash
# 保留最近 30 秒的数据在缓存中
ros2 bag record -a --max-cache-size 0 --max-cache-duration 30
```

### 2. Snapshot 模式 + 大小限制

```bash
# 保留最近约 100MB 的数据
ros2 bag record -a --snapshot-mode --max-cache-size 100000000 --max-cache-duration 0
```

### 3. Snapshot 模式 + 双重限制

```bash
# 保留最近 10 秒且不超过 50MB 的数据
ros2 bag record -a --snapshot-mode --max-cache-size 50000000 --max-cache-duration 10
```

### 4. Snapshot 模式 + 仅时间限制

```bash
# 保留最近 7 秒的数据（不限制大小）
ros2 bag record -a --snapshot-mode --max-cache-size 0 --max-cache-duration 7
```

### 5. 触发 Snapshot

```bash
ros2 service call /rosbag2_recorder/snapshot rosbag2_interfaces/srv/Snapshot
```

---

## 注意事项

1. **双缓冲机制**: 由于使用双缓冲，最坏情况下内存使用可能达到 `2 × max-cache-size`

2. **时间限制的有效期**:
   - Snapshot 模式: 记录的时间跨度对应触发时的当前缓冲区窗口（最多 `--max-cache-duration` 秒）
   - 普通模式: 由于生产者/消费者缓冲区交换和写入节奏，有效观察时间跨度可能达到约 `2 × --max-cache-duration` 秒

3. **Snapshot 模式要求**: 至少启用一个限制条件（大小或时间）

4. **时间戳依赖**: 功能依赖于消息的 `recv_timestamp` 字段

---

## 迁移指南

### 对于现有代码

1. **StorageOptions 初始化**: 如果直接构造 `StorageOptions`，需要添加 `max_cache_duration` 字段

2. **缓存类构造**: 如果直接创建 `MessageCache` 或 `CircularMessageCache`，需要添加 `max_buffer_duration` 参数

3. **默认值**: `max_cache_duration` 默认为 0，表示不启用时间限制（保持原有行为）

### 代码示例

```cpp
// 旧代码
rosbag2_storage::StorageOptions options;
options.max_cache_size = 100000000;

// 新代码（显式设置）
rosbag2_storage::StorageOptions options;
options.max_cache_size = 100000000;
options.max_cache_duration = 10;  // 新增

// 旧代码
auto cache = std::make_shared<rosbag2_cpp::cache::MessageCache>(max_size);

// 新代码
auto cache = std::make_shared<rosbag2_cpp::cache::MessageCache>(max_size, max_duration);
```

---

## 相关 Issue/PR

- 解决 Issue: https://github.com/ros2/rosbag2/issues/663
- 类似 ROS 1 的 `rosbag_snapshot` 功能
