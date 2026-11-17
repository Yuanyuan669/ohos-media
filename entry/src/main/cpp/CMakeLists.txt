cmake_minimum_required(VERSION 3.5.0)
project(hevcdec)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/libde265/include)

add_library(hevcdec SHARED
    hevc_napi.cpp
    mp4_hevc.cpp
)

target_link_libraries(hevcdec PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/libde265/libde265.a
    ace_napi.z
    hilog_ndk.z
    z
)
