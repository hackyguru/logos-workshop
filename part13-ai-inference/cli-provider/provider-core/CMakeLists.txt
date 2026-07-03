cmake_minimum_required(VERSION 3.14)
project(InferenceProviderPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

# OpenSSL provides Ed25519/X25519/HMAC for InferenceIdentity (accounts_module's
# own signHash is broken, so all signing is done in-plugin). `openssl` is
# declared in metadata.json (nix.packages.runtime) so it lands in buildInputs —
# same pattern as part9's poker-core.
logos_module(
    NAME inference_provider
    SOURCES
        src/provider_interface.h
        src/inference_identity.h
        src/inference_identity.cpp
        src/provider_plugin.h
        src/provider_plugin.cpp
    FIND_PACKAGES
        OpenSSL
    LINK_LIBRARIES
        OpenSSL::Crypto
)
