add_library(OakTextView STATIC)
file(GLOB _src src/*.cc src/*.mm)
target_sources(OakTextView PRIVATE ${_src})
textmate_framework(OakTextView)
target_link_libraries(OakTextView PUBLIC
  BundleMenu BundlesManager Find HTMLOutput MenuBuilder OakAppKit OakCommand
  OakFilterList OakFoundation OakSystem Preferences buffer bundles cf command
  crash document editor file io layout lsp ns scm settings text theme
  "-framework Cocoa")

# OakSwiftUI — include path for the generated Swift header
if(OakSwiftUI_LIB)
  target_include_directories(OakTextView PRIVATE "${OakSwiftUI_INCLUDE_DIR}")
  target_link_libraries(OakTextView PUBLIC ${OakSwiftUI_LIB})
endif()

textmate_add_tests(OakTextView)
if(BUILD_TESTING)
  add_executable(inlay_hint_lifecycle tests/inlay_hint_lifecycle.mm)
  target_link_libraries(inlay_hint_lifecycle PRIVATE OakTextView ${TEXTMATE_DEBUG_LIBS})
  if(OakSwiftUI_LIB)
    target_include_directories(inlay_hint_lifecycle PRIVATE "${OakSwiftUI_INCLUDE_DIR}")
  endif()
  add_test(NAME inlay_hint_lifecycle COMMAND inlay_hint_lifecycle)
endif()
