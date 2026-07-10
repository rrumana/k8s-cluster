cmake_minimum_required(VERSION 3.20)
project(qbittorrent_merge_history LANGUAGES CXX)

find_package(Qt6 REQUIRED COMPONENTS Core)
find_package(SQLite3 REQUIRED)

add_executable(qbittorrent-merge-history main.cpp)
target_compile_features(qbittorrent-merge-history PRIVATE cxx_std_20)
target_link_libraries(qbittorrent-merge-history PRIVATE Qt6::Core SQLite3::SQLite3)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(qbittorrent-merge-history PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
