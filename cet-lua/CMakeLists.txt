cmake_minimum_required(VERSION 3.20)
project(cet-lua CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(VENDOR "${CMAKE_SOURCE_DIR}/vendor")

# LuaJIT (prebuilt static lib, arm64/GC64, interpreter-usable). Built by vendor/LuaJIT `make amalg`.
set(LUAJIT_DIR "${VENDOR}/LuaJIT/src")
add_library(luajit STATIC IMPORTED)
set_target_properties(luajit PROPERTIES IMPORTED_LOCATION "${LUAJIT_DIR}/libluajit.a")

# sol2 (header-only) + RED4ext.SDK (header-only, macOS-patched fork).
add_library(sol2 INTERFACE)
target_include_directories(sol2 INTERFACE "${VENDOR}/sol2/include")
add_library(red4ext_sdk INTERFACE)
target_include_directories(red4ext_sdk INTERFACE "${VENDOR}/RED4ext.SDK/include")

file(GLOB_RECURSE CETLUA_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/*.cpp")

add_library(cet-lua SHARED ${CETLUA_SOURCES})
target_include_directories(cet-lua PRIVATE "${CMAKE_SOURCE_DIR}/src" "${LUAJIT_DIR}")
target_link_libraries(cet-lua PRIVATE luajit sol2 red4ext_sdk)

target_compile_definitions(cet-lua PRIVATE
  SOL_LUAJIT=1
  SOL_ALL_SAFETIES_ON=1
  SOL_EXCEPTIONS_SAFE_PROPAGATION=1
  SOL_NO_EXCEPTIONS=0
)
target_compile_options(cet-lua PRIVATE -fexceptions -frtti -Wno-deprecated-declarations)

# RED4ext plugin dylib naming: <name>.dylib, no "lib" prefix, dropped into red4ext/plugins/cet-lua/.
set_target_properties(cet-lua PROPERTIES PREFIX "" OUTPUT_NAME "cet-lua" SUFFIX ".dylib")

# LuaJIT on macOS pulls in the system Lua deps (none) + needs the ObjC/System frameworks the SDK touches.
target_link_libraries(cet-lua PRIVATE "-framework CoreFoundation" "-framework Foundation")
