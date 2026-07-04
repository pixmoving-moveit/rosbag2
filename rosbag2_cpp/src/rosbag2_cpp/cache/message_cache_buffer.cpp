// Copyright 2020, Robotec.ai sp. z o.o.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <memory>
#include <stdexcept>
#include <vector>

#include "rcutils/time.h"
#include "rosbag2_cpp/cache/cache_buffer_interface.hpp"
#include "rosbag2_cpp/cache/message_cache_buffer.hpp"
#include "rosbag2_cpp/logging.hpp"

namespace rosbag2_cpp
{
namespace cache
{

MessageCacheBuffer::MessageCacheBuffer(size_t max_cache_size, uint32_t max_cache_duration)
: max_bytes_size_(max_cache_size), max_cache_duration_ns_(RCUTILS_S_TO_NS(max_cache_duration))
{
  if (max_bytes_size_ == 0 && max_cache_duration_ns_ == 0) {
    throw std::invalid_argument(
            "Invalid arguments for MessageCacheBuffer. "
            "Both max_cache_size and max_cache_duration are zero.");
  }
}

bool MessageCacheBuffer::push(CacheBufferInterface::buffer_element_t msg)
{
  if (!msg || !msg->serialized_data) {
    ROSBAG2_CPP_LOG_ERROR("Attempted to push null message into cache buffer. Dropping message!");
    return false;
  }

  if (drop_messages_) {
    return false;
  }

  if (max_cache_duration_ns_ > 0 && !buffer_.empty()) {
    if (msg->recv_timestamp < buffer_.back()->recv_timestamp) {
      ROSBAG2_CPP_LOG_ERROR_STREAM(
        "Received out-of-order message timestamp " << msg->recv_timestamp <<
          " after " << buffer_.back()->recv_timestamp << ". Dropping new message!");
      return false;
    }

    const auto prospective_buffer_duration = msg->recv_timestamp - buffer_.front()->recv_timestamp;
    if (static_cast<uint64_t>(prospective_buffer_duration) > max_cache_duration_ns_) {
      drop_messages_ = true;
    }
  }

  if (drop_messages_) {
    return false;
  }

  buffer_bytes_size_ += msg->serialized_data->buffer_length;
  buffer_.push_back(msg);

  if (max_bytes_size_ > 0 && buffer_bytes_size_ >= max_bytes_size_) {
    drop_messages_ = true;
  }

  return true;
}

void MessageCacheBuffer::clear()
{
  buffer_.clear();
  buffer_bytes_size_ = 0u;
  drop_messages_ = false;
}

size_t MessageCacheBuffer::size()
{
  return buffer_.size();
}

const std::vector<CacheBufferInterface::buffer_element_t> & MessageCacheBuffer::data()
{
  return buffer_;
}

}  // namespace cache
}  // namespace rosbag2_cpp
