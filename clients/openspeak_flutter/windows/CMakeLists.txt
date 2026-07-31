# Project-level configuration.
cmake_minimum_required(VERSION 3.15)
project(OpenSpeak LANGUAGES C CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "OpenSpeak")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.15...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# flutter_webrtc 1.4.0 parses the audio constraints but discards them when it
# creates the Windows audio source. Compile a local copy with OpenSpeak's fixed
# AEC/AGC-on, NS/high-pass-off capture options until the dependency fixes it.
set(OPENSPEAK_WEBRTC_MEDIA_STREAM_SOURCE
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_webrtc/common/cpp/src/flutter_media_stream.cc")
file(READ "${OPENSPEAK_WEBRTC_MEDIA_STREAM_SOURCE}"
  OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT)

set(OPENSPEAK_WEBRTC_DEFAULT_AUDIO_SOURCE
  [[base_->factory_->CreateAudioSource("audio_input");]])
set(OPENSPEAK_WEBRTC_CONFIGURED_AUDIO_SOURCE [[base_->factory_->CreateAudioSource(
            "audio_input", libwebrtc::RTCAudioSource::SourceType::kMicrophone,
            [] {
              libwebrtc::RTCAudioOptions options;
              options.echo_cancellation = true;
              options.auto_gain_control = true;
              options.noise_suppression = false;
              options.highpass_filter = false;
              return options;
            }());]])
foreach(OPENSPEAK_WEBRTC_OLD_VALUE IN ITEMS
    "${OPENSPEAK_WEBRTC_DEFAULT_AUDIO_SOURCE}"
    [[settings[EncodableValue("autoGainControl")] = EncodableValue(true);]]
    [[settings[EncodableValue("noiseSuppression")] = EncodableValue(true);]])
  string(FIND "${OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT}"
    "${OPENSPEAK_WEBRTC_OLD_VALUE}" OPENSPEAK_WEBRTC_MATCH)
  if(OPENSPEAK_WEBRTC_MATCH EQUAL -1)
    message(FATAL_ERROR "flutter_webrtc 1.4.0 audio source changed; update the OpenSpeak patch")
  endif()
endforeach()
string(REPLACE "${OPENSPEAK_WEBRTC_DEFAULT_AUDIO_SOURCE}"
  "${OPENSPEAK_WEBRTC_CONFIGURED_AUDIO_SOURCE}"
  OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT
  "${OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT}")
string(REPLACE
  [[settings[EncodableValue("noiseSuppression")] = EncodableValue(true);]]
  [[settings[EncodableValue("noiseSuppression")] = EncodableValue(false);]]
  OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT
  "${OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT}")

set(OPENSPEAK_WEBRTC_PATCHED_MEDIA_STREAM
  "${CMAKE_CURRENT_BINARY_DIR}/flutter_media_stream_openspeak.cc")
file(WRITE "${OPENSPEAK_WEBRTC_PATCHED_MEDIA_STREAM}"
  "${OPENSPEAK_WEBRTC_MEDIA_STREAM_CONTENT}")
get_target_property(OPENSPEAK_WEBRTC_SOURCES flutter_webrtc_plugin SOURCES)
list(LENGTH OPENSPEAK_WEBRTC_SOURCES OPENSPEAK_WEBRTC_SOURCE_COUNT)
list(FILTER OPENSPEAK_WEBRTC_SOURCES EXCLUDE REGEX "flutter_media_stream\\.cc$")
list(LENGTH OPENSPEAK_WEBRTC_SOURCES OPENSPEAK_WEBRTC_PATCHED_SOURCE_COUNT)
math(EXPR OPENSPEAK_WEBRTC_EXPECTED_SOURCE_COUNT
  "${OPENSPEAK_WEBRTC_PATCHED_SOURCE_COUNT} + 1")
if(NOT OPENSPEAK_WEBRTC_SOURCE_COUNT EQUAL OPENSPEAK_WEBRTC_EXPECTED_SOURCE_COUNT)
  message(FATAL_ERROR "Unable to replace flutter_webrtc's Windows audio source")
endif()
set_property(TARGET flutter_webrtc_plugin PROPERTY SOURCES
  "${OPENSPEAK_WEBRTC_SOURCES};${OPENSPEAK_WEBRTC_PATCHED_MEDIA_STREAM}")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../native/rnnoise/COPYING"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses"
  RENAME "RNNoise.txt"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
