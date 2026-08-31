cmake_minimum_required(VERSION 3.18.1)
project(nexus_ndk)

add_library(nexus_ndk SHARED nexus_ndk.cpp)

find_library(log-lib log)
target_link_libraries(nexus_ndk ${log-lib})
