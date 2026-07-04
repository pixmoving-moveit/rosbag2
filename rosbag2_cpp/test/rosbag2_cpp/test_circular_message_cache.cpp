// Copyright 2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

#include <gmock/gmock.h>

#include <chrono>
#include <cmath>
#include <list>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

#include "rcutils/time.h"
#include "rosbag2_storage/ros_helper.hpp"
#include "rosbag2_storage/serialized_bag_message.hpp"

#include "rosbag2_cpp/cache/circular_message_cache.hpp"

using namespace testing;  // NOLINT
using namespace std::chrono_literals;

namespace
{
inline size_t abs_diff(size_t a, size_t b)
{
  return a < b ? b - a : a - b;
}

std::shared_ptr<rosbag2_storage::SerializedBagMessage> make_test_msg(
  const rcutils_time_point_value_t recv_timestamp = 0,
  const std::string & content = "")
{
  static uint32_t counter = 0;
  const std::string msg_content = content.empty() ? "Hello" + std::to_string(counter++) : content;
  auto message = std::make_shared<rosbag2_storage::SerializedBagMessage>();
  message->topic_name = "test_topic";
  message->recv_timestamp = recv_timestamp;
  message->send_timestamp = recv_timestamp;
  message->serialized_data = rosbag2_storage::make_serialized_message(
    msg_content.c_str(), msg_content.length());
  return message;
}

std::string deserialize_message(std::shared_ptr<rcutils_uint8_array_t> serialized_message)
{
  std::unique_ptr<uint8_t[]> copied(new uint8_t[serialized_message->buffer_length + 1]);
  std::copy(
    serialized_message->buffer,
    serialized_message->buffer + serialized_message->buffer_length,
    copied.get());
  copied.get()[serialized_message->buffer_length] = '\0';
  std::string message_content(reinterpret_cast<char *>(copied.get()));
  return message_content;
}
}  // namespace

class CircularMessageCacheTest : public Test
{
public:
  CircularMessageCacheTest() {}

  virtual ~CircularMessageCacheTest() = default;

  const size_t cache_size_ {1 * 500};  // 500B cache
};

TEST_F(CircularMessageCacheTest, circular_message_cache_overwrites_old) {
  const unsigned message_count = 100;

  auto circular_message_cache = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    cache_size_);

  for (unsigned i = 0; i < message_count; ++i) {
    auto msg = make_test_msg();
    circular_message_cache->push(msg);
  }
  // Swap cache
  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();

  auto consumer_buffer = circular_message_cache->get_consumer_buffer();
  EXPECT_THAT(consumer_buffer->size(), Ne(0u));

  auto message_vector = consumer_buffer->data();
  std::string first_message = deserialize_message(message_vector.front()->serialized_data);
  circular_message_cache->release_consumer_buffer();

  // Old messages should be dropped
  EXPECT_THAT(first_message, StrNe("Hello0"));

  size_t message_data_size = 0;

  for (auto & msg : message_vector) {
    message_data_size += msg->serialized_data->buffer_length;
  }

  size_t cache_size_diff = abs_diff(cache_size_, message_data_size);
  size_t allowed_diff{10};

  // Actual stored data size should be roughly the desired cache size
  EXPECT_THAT(cache_size_diff, Lt(allowed_diff));
}

TEST_F(CircularMessageCacheTest, circular_message_cache_ensure_empty) {
  const unsigned message_count = 100;

  auto circular_message_cache = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    cache_size_);

  for (unsigned i = 0; i < message_count; ++i) {
    auto msg = make_test_msg();
    circular_message_cache->push(msg);
  }
  // Swap filled cache to secondary
  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();
  EXPECT_THAT(circular_message_cache->get_consumer_buffer()->size(), Ne(0u));
  circular_message_cache->release_consumer_buffer();

  // Swap back to primary (expected to empty buffer)
  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();

  // Swap back to secondary without adding messages
  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();
  // Cache should have been emptied
  EXPECT_THAT(circular_message_cache->get_consumer_buffer()->size(), Eq(0u));
  circular_message_cache->release_consumer_buffer();
}

TEST_F(CircularMessageCacheTest, circular_message_cache_rejects_null_message) {
  auto circular_message_cache_ = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    cache_size_);

  ASSERT_NO_THROW(circular_message_cache_->push(nullptr));
  ASSERT_NO_THROW(circular_message_cache_->push(nullptr));
}

TEST_F(CircularMessageCacheTest, constructor_throws_if_both_limits_are_zero) {
  EXPECT_THROW(rosbag2_cpp::cache::CircularMessageCache(0, 0), std::invalid_argument);
}

TEST_F(CircularMessageCacheTest, time_only_buffer_drops_old_messages_by_duration) {
  constexpr uint32_t max_buffer_duration = 1;
  auto circular_message_cache = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    /*max_buffer_size=*/0, max_buffer_duration);

  const auto base = 1s;
  const auto messages_interval = 100ms;
  constexpr size_t message_count = 30;
  const size_t expected_count = 1s / messages_interval + 1;
  for (size_t i = 0; i < message_count; i++) {
    auto ts = base + (i * messages_interval);
    auto msg = make_test_msg(
      static_cast<rcutils_time_point_value_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(ts).count()));
    circular_message_cache->push(msg);
  }

  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();

  auto consumer_buffer = circular_message_cache->get_consumer_buffer();
  auto messages = consumer_buffer->data();
  circular_message_cache->release_consumer_buffer();

  ASSERT_EQ(messages.size(), expected_count);
  const auto oldest = messages.front()->recv_timestamp;
  const auto newest = messages.back()->recv_timestamp;
  EXPECT_LE(newest - oldest, RCUTILS_S_TO_NS(max_buffer_duration));

  const auto expected_newest = base + ((message_count - 1) * messages_interval);
  EXPECT_EQ(
    newest,
    static_cast<rcutils_time_point_value_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(expected_newest).count()));
  const auto expected_oldest = expected_newest - 1s;
  EXPECT_EQ(
    oldest,
    static_cast<rcutils_time_point_value_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(expected_oldest).count()));
}

TEST_F(CircularMessageCacheTest, time_and_size_buffer_respects_both_limits) {
  constexpr size_t max_buffer_size = 200;
  constexpr uint32_t max_buffer_duration = 2;
  auto circular_message_cache = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    max_buffer_size, max_buffer_duration);

  const auto base = 10s;
  constexpr size_t message_count = 100;
  const auto messages_interval = 50ms;
  for (size_t i = 0; i < message_count; i++) {
    auto ts = base + (i * messages_interval);
    auto msg = make_test_msg(
      static_cast<rcutils_time_point_value_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(ts).count()),
      std::string(7, 'x'));
    circular_message_cache->push(msg);
  }

  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();

  auto consumer_buffer = circular_message_cache->get_consumer_buffer();
  auto messages = consumer_buffer->data();
  circular_message_cache->release_consumer_buffer();

  ASSERT_GT(messages.size(), 0u);

  size_t total_size = 0;
  for (const auto & msg : messages) {
    total_size += msg->serialized_data->buffer_length;
  }
  EXPECT_LE(total_size, max_buffer_size);

  const auto oldest = messages.front()->recv_timestamp;
  const auto newest = messages.back()->recv_timestamp;
  EXPECT_LE(newest - oldest, RCUTILS_S_TO_NS(max_buffer_duration));
}

TEST_F(CircularMessageCacheTest, handles_out_of_order_timestamps_gracefully) {
  constexpr uint32_t max_duration_sec = 2;
  auto circular_message_cache = std::make_shared<rosbag2_cpp::cache::CircularMessageCache>(
    /*max_buffer_size=*/0, max_duration_sec);

  auto newer_message = make_test_msg(RCUTILS_S_TO_NS(5));
  auto older_message = make_test_msg(RCUTILS_S_TO_NS(3));

  circular_message_cache->push(newer_message);
  circular_message_cache->push(older_message);

  circular_message_cache->notify_data_ready();
  circular_message_cache->swap_buffers();

  auto buffer = circular_message_cache->get_consumer_buffer()->data();
  EXPECT_EQ(buffer.size(), 1u);
  circular_message_cache->release_consumer_buffer();
}
