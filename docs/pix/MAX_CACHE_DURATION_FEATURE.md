# rosbag2 `--max-cache-duration` 功能开发文档

## 一、功能概述

为 rosbag2 的 Recorder 添加基于**时间限制**的缓存功能，实现基于时间的 Snapshot 功能。现在缓存可以同时或单独受以下两种限制：

- **大小限制** (`--max-cache-size`): 按字节数限制
- **时间限制** (`--max-cache-duration`): 按秒数限制

### 使用场景

- **仅时间限制**: 保留最近 N 秒的数据，不关心数据量大小
- **仅大小限制**: 保留最近 N 字节的数据（原有功能）
- **双重限制**: 同时满足时间和大小限制

## 二、修改的文件清单

### 2.1 数据结构与存储选项

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 1 | `rosbag2_storage/include/rosbag2_storage/storage_options.hpp` | 添加字段 | 添加 `max_cache_duration` 字段 (uint32_t, 默认 0) |
| 2 | `rosbag2_storage/src/rosbag2_storage/storage_options.cpp` | YAML 编解码 | 添加 encode/decode 支持 |

### 2.2 缓存缓冲区实现

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 3 | `rosbag2_cpp/include/rosbag2_cpp/cache/message_cache_buffer.hpp` | API 修改 | 添加 `max_cache_duration` 参数和 `max_cache_duration_ns_` 成员 |
| 4 | `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_buffer.cpp` | 实现修改 | 实现时间限制逻辑：计算缓冲区持续时间，超限时丢弃新消息 |
| 5 | `rosbag2_cpp/include/rosbag2_cpp/cache/message_cache_circular_buffer.hpp` | API 修改 | 添加 `max_cache_duration` 参数和 `max_cache_duration_ns_` 成员 |
| 6 | `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_circular_buffer.cpp` | 实现修改 | 实现时间限制逻辑：超限时循环移除旧消息 |

### 2.3 缓存类

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 7 | `rosbag2_cpp/include/rosbag2_cpp/cache/message_cache.hpp` | API 修改 | 构造函数添加 `max_buffer_duration` 参数 |
| 8 | `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache.cpp` | 实现修改 | 传递时间参数给缓冲区，添加空消息检查 |
| 9 | `rosbag2_cpp/include/rosbag2_cpp/cache/circular_message_cache.hpp` | API 修改 | 构造函数添加 `max_buffer_duration` 参数，更新文档注释 |
| 10 | `rosbag2_cpp/src/rosbag2_cpp/cache/circular_message_cache.cpp` | 实现修改 | 传递时间参数给缓冲区 |

### 2.4 写入器

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 11 | `rosbag2_cpp/src/rosbag2_cpp/writers/sequential_writer.cpp` | 逻辑修改 | 更新缓存启用条件：`max_cache_size > 0 \|\| max_cache_duration > 0` |

### 2.5 其他实现文件

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 12 | `rosbag2_cpp/src/rosbag2_cpp/reindexer.cpp` | 代码优化 | 简化 `StorageOptions` 复制逻辑 |

### 2.6 CLI 接口

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 13 | `ros2bag/ros2bag/verb/record.py` | 功能添加 | 添加 `--max-cache-duration` 参数和验证逻辑 |

### 2.7 Python 绑定

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 14 | `rosbag2_py/src/rosbag2_py/_storage.cpp` | Python 绑定 | 添加 `max_cache_duration` 的 Python 绑定 |

### 2.8 测试文件

| 序号 | 文件路径 | 修改类型 | 说明 |
|-----|---------|---------|------|
| 15 | `rosbag2_cpp/test/rosbag2_cpp/test_circular_message_cache.cpp` | 测试添加 | 添加 7 个新测试用例 |
| 16 | `rosbag2_cpp/test/rosbag2_cpp/test_message_cache.cpp` | 测试添加 | 添加 3 个新测试用例 |
| 17 | `rosbag2_cpp/CMakeLists.txt` | 构建配置 | 更新测试链接库 |
| 18 | `rosbag2_storage_default_plugins/test/.../storage_test_fixture.hpp` | 测试修复 | 修复 `StorageOptions` 初始化 |
| 19 | `rosbag2_storage_default_plugins/test/.../test_sqlite_storage.cpp` | 测试修复 | 修复 `StorageOptions` 初始化 |

## 三、核心实现逻辑

### 3.1 数据结构修改

```cpp
// rosbag2_storage/include/rosbag2_storage/storage_options.hpp
struct StorageOptions
{
  // ... 其他字段
  
  // 原有字段
  uint64_t max_cache_size = 0;
  
  // 新增字段：最大缓存持续时间（秒）
  uint32_t max_cache_duration = 0;
  
  // ... 其他字段
};
```

### 3.2 MessageCacheBuffer（普通模式）

**实现文件**: `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_buffer.cpp`

**核心逻辑**: 超出限制时丢弃新消息

```cpp
bool MessageCacheBuffer::push(CacheBufferInterface::buffer_element_t msg)
{
  // 1. 空消息检查
  if (!msg || !msg->serialized_data) {
    ROSBAG2_CPP_LOG_ERROR("Attempted to push null message into cache buffer. Dropping message!");
    return false;
  }

  // 2. 计算预期缓冲区持续时间
  rcutils_time_point_value_t prospected_buffer_duration = 0;
  
  // 只有在启用时间限制且缓冲区已有消息时才计算
  if (max_cache_duration_ns_ > 0 && buffer_.size() > 0) {
    // 使用 time_stamp 计算时间差（Humble 分支）
    // buffer_.front() 是最旧的消息
    // msg 是将要添加的新消息
    prospected_buffer_duration = msg->time_stamp - buffer_.front()->time_stamp;
    
    // 检查时间戳是否乱序（新消息时间早于最旧消息）
    if (prospected_buffer_duration < 0) {
      ROSBAG2_CPP_LOG_ERROR_STREAM("Can't calculate prospected cache buffer duration...");
      return false;  // 丢弃新消息
    }
  }

  bool pushed = false;

  // 3. 检查是否可以添加消息
  if (!drop_messages_) {
    // 3.1 检查时间限制
    if (max_cache_duration_ns_ > 0) {
      // 如果添加后持续时间超过限制，标记缓冲区已满
      if (static_cast<uint64_t>(prospected_buffer_duration) > max_cache_duration_ns_) {
        drop_messages_ = true;  // 设置标志，后续消息都将被丢弃
      }
    }

    // 3.2 检查大小限制
    if (max_bytes_size_ > 0 && !buffer_.empty()) {
      if (buffer_bytes_size_ + msg->serialized_data->buffer_length > max_bytes_size_) {
        drop_messages_ = true;
      }
    }

    // 3.3 如果未超限，添加消息
    if (!drop_messages_) {
      buffer_bytes_size_ += msg->serialized_data->buffer_length;
      buffer_.push_back(msg);
      pushed = true;
    }
  }
  return pushed;  // 返回 true(成功) 或 false(丢弃)
}
```

**判断流程图**:
```
新消息到达
    ↓
计算 prospected_buffer_duration = 新消息时间 - 最旧消息时间
    ↓
prospected_buffer_duration > max_cache_duration_ns_ ?
    ↓
    是 → drop_messages_ = true → 丢弃新消息
    否 → 添加消息到缓冲区
```

### 3.3 MessageCacheCircularBuffer（Snapshot 模式）

**实现文件**: `rosbag2_cpp/src/rosbag2_cpp/cache/message_cache_circular_buffer.cpp`

**核心逻辑**: 超出限制时循环移除旧消息

```cpp
bool MessageCacheCircularBuffer::push(CacheBufferInterface::buffer_element_t msg)
{
  // 1. 空消息检查
  if (!msg || !msg->serialized_data) {
    return false;
  }

  // 2. 单条消息超过大小限制时丢弃（仅当大小限制启用时）
  if (max_bytes_size_ > 0 && msg->serialized_data->buffer_length > max_bytes_size_) {
    ROSBAG2_CPP_LOG_WARN("Last message exceeds snapshot buffer size. Dropping message!");
    return false;
  }

  // 3. 移除旧消息直到满足大小限制
  while (max_bytes_size_ > 0 &&
    buffer_bytes_size_ > (max_bytes_size_ - msg->serialized_data->buffer_length))
  {
    buffer_bytes_size_ -= buffer_.front()->serialized_data->buffer_length;
    buffer_.pop_front();  // 循环移除最旧的消息
  }

  // 4. 移除旧消息直到满足时间限制（关键部分）
  if (max_cache_duration_ns_ > 0 && buffer_.size() > 0) {
    // 计算预期持续时间: 新消息时间 - 当前最旧消息时间
    auto prospected_buffer_duration = msg->time_stamp - buffer_.front()->time_stamp;
    
    // 时间戳乱序检查
    if (prospected_buffer_duration < 0) {
      ROSBAG2_CPP_LOG_ERROR_STREAM("Can't calculate prospected circular cache buffer duration...");
      return false;  // 丢弃新消息
    }

    // 循环移除旧消息直到满足时间限制
    while (buffer_.size() > 0 && 
           static_cast<uint64_t>(prospected_buffer_duration) > max_cache_duration_ns_) {
      buffer_bytes_size_ -= buffer_.front()->serialized_data->buffer_length;
      buffer_.pop_front();  // 移除最旧的消息
      
      // 重新计算持续时间（新消息时间 - 新的最旧消息时间）
      prospected_buffer_duration = msg->time_stamp - buffer_.front()->time_stamp;
    }
  }

  // 5. 添加新消息到缓冲区末尾
  buffer_bytes_size_ += msg->serialized_data->buffer_length;
  buffer_.push_back(msg);

  return true;
}
```

**判断流程图**:
```
新消息到达
    ↓
计算 prospected_buffer_duration = 新消息时间 - 最旧消息时间
    ↓
prospected_buffer_duration > max_cache_duration_ns_ ?
    ↓
    是 → pop_front() 移除最旧消息 → 重新计算 → 再次检查
    否 → 添加新消息到缓冲区
```

### 3.4 两种模式对比

| 特性 | MessageCacheBuffer (普通模式) | MessageCacheCircularBuffer (Snapshot 模式) |
|------|------------------------------|-------------------------------------------|
| **超限行为** | 丢弃新消息 | 移除旧消息，保留新消息 |
| **使用场景** | 普通录制，保证不丢旧数据 | Snapshot，保证有最新数据 |
| **双缓冲** | 是 | 是 |
| **缓冲区满后** | 不再接受新消息直到交换 | 循环覆盖旧消息 |

## 四、使用示例

### 4.1 仅时间限制
```bash
# 保留最近 30 秒的数据
ros2 bag record -a --max-cache-size 0 --max-cache-duration 30
```

### 4.2 Snapshot + 大小限制
```bash
# 保留最近约 100MB 的数据
ros2 bag record -a --snapshot-mode --max-cache-size 100000000 --max-cache-duration 0
```

### 4.3 Snapshot + 双重限制
```bash
# 保留最近 10 秒且不超过 50MB 的数据
ros2 bag record -a --snapshot-mode --max-cache-size 50000000 --max-cache-duration 10
```

### 4.4 触发 Snapshot
```bash
ros2 service call /rosbag2_recorder/snapshot rosbag2_interfaces/srv/Snapshot
```

## 五、关键设计决策

### 5.1 类型选择
- `max_cache_duration` 使用 `uint32_t`（秒），而非 `rclcpp::Duration`
- 实际应用不需要亚秒级精度
- 避免对 rclcpp 层的依赖
- 简化操作

### 5.2 双重限制
- 可以同时启用大小和时间限制，任一条件触发都会生效

### 5.3 Snapshot 模式要求
- 至少启用一个限制条件（大小或时间）

### 5.4 时间戳来源
- 功能依赖于消息的 `time_stamp` 字段（Humble 分支）
- 这是消息**到达缓存的时间**，而非消息内部的 header.stamp

## 六、新增测试用例

### 6.1 CircularMessageCacheTest

| 测试名称 | 说明 |
|---------|------|
| `constructor_throws_if_both_limits_are_zero` | 验证两个限制都为零时抛出异常 |
| `time_only_buffer_drops_old_messages_by_duration` | 仅时间限制，验证旧消息被移除 |
| `size_only_buffer_drops_old_messages_by_size` | 仅大小限制，验证旧消息被移除 |
| `time_and_size_buffer_respects_both_limits` | 双重限制，验证同时满足 |
| `rejects_message_exceeding_size_limit` | 单条消息超过大小限制时拒绝 |
| `handles_out_of_order_timestamps_gracefully` | 处理乱序时间戳 |
| `circular_message_cache_handles_null_message` | 空消息处理 |

### 6.2 MessageCacheTest

| 测试名称 | 说明 |
|---------|------|
| `message_cache_handles_null_message` | 空消息处理 |
| `constructor_throws_if_both_limits_are_zero` | 验证两个限制都为零时抛出异常 |
| `message_cache_buffer_time_only_limits_by_duration` | 仅时间限制测试 |

## 七、与参考文档的差异

### 7.1 字段名差异

| 参考文档 (Rolling) | Humble 分支 |
|-------------------|------------|
| `recv_timestamp` | `time_stamp` |

### 7.2 push() 返回类型

| 类 | 参考文档 | Humble 分支 |
|---|---------|------------|
| `MessageCache` | `bool` | `void` |
| `CircularMessageCache` | `bool` | `void` |

## 八、编译和测试

### 8.1 编译命令
```bash
cd ~/pix/test/ros2_ws
colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release
```

### 8.2 运行测试
```bash
cd ~/pix/test/ros2_ws
source install/setup.bash
ros2 run rosbag2_cpp test_circular_message_cache
ros2 run rosbag2_cpp test_message_cache
```

## 九、注意事项

1. **双缓冲机制**: 由于使用双缓冲，最坏情况下内存使用可能达到 `2 × max-cache-size`

2. **时间限制的有效期**:
   - Snapshot 模式: 记录的时间跨度对应触发时的当前缓冲区窗口（最多 `--max-cache-duration` 秒）
   - 普通模式: 由于生产者/消费者缓冲区交换和写入节奏，有效观察时间跨度可能达到约 `2 × --max-cache-duration` 秒

3. **Snapshot 模式要求**: 至少启用一个限制条件（大小或时间）

4. **时间戳依赖**: 功能依赖于消息的 `time_stamp` 字段

## 十、相关 Issue/PR

- 解决 Issue: https://github.com/ros2/rosbag2/issues/663
- 参考 PR: https://github.com/ros2/rosbag2/pull/2289
- 类似 ROS 1 的 `rosbag_snapshot` 功能

---

**文档版本**: 1.0  
**创建日期**: 2026-03-03  
**适用分支**: pixmoving-humble (基于 ROS 2 Humble)
