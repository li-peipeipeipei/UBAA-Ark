cmake_minimum_required(VERSION 3.5.0)
project(mnncaptcha)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ROOT ${CMAKE_CURRENT_SOURCE_DIR})

add_library(mnncaptcha SHARED mnn_captcha.cpp)

target_include_directories(mnncaptcha PRIVATE ${ROOT}/include)

# 预编译的 MNN（官方 mnn_3.6.2_harmony_arm64_cpu 发布件）
add_library(mnn SHARED IMPORTED)
set_target_properties(mnn PROPERTIES
    IMPORTED_LOCATION ${ROOT}/libs/${OHOS_ARCH}/libMNN.so)

target_link_libraries(mnncaptcha PUBLIC mnn libace_napi.z.so libhilog_ndk.z.so)
