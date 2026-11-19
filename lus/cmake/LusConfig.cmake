include(CMakeFindDependencyMacro)

find_dependency(OpenSSL)
find_dependency(c-ares CONFIG)
find_dependency(ZLIB)
find_dependency(zstd CONFIG)
find_dependency(unofficial-brotli CONFIG)
find_dependency(lz4 CONFIG)

get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

if(NOT TARGET Lus::sqlite3)
  add_library(Lus::sqlite3 STATIC IMPORTED)
  set_target_properties(Lus::sqlite3 PROPERTIES
    IMPORTED_LOCATION "${_IMPORT_PREFIX}/lib/sqlite3.lib"
  )
endif()

if(NOT TARGET Lus::lus)
  add_library(Lus::lus STATIC IMPORTED)
  set_target_properties(Lus::lus PROPERTIES
    IMPORTED_LOCATION "${_IMPORT_PREFIX}/lib/lus.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/include"
    INTERFACE_LINK_LIBRARIES
      "Lus::sqlite3;OpenSSL::SSL;OpenSSL::Crypto;c-ares::cares;ZLIB::ZLIB;zstd::libzstd_static;unofficial::brotli::brotlienc;unofficial::brotli::brotlidec;lz4::lz4;ws2_32"
  )
endif()

unset(_IMPORT_PREFIX)
