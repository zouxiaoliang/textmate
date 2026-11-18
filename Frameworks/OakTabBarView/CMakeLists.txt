# rave: require OakFoundation OakAppKit TMFileReference, frameworks Cocoa
add_library(OakTabBarView STATIC)
file(GLOB _src src/*.mm)
target_sources(OakTabBarView PRIVATE ${_src})
textmate_framework(OakTabBarView)
target_link_libraries(OakTabBarView PUBLIC OakFoundation OakAppKit TMFileReference
  "-framework Cocoa")
target_include_directories(OakTabBarView PRIVATE
  $<TARGET_PROPERTY:Preferences,INTERFACE_INCLUDE_DIRECTORIES>)

# Offscreen render test: draws the bar with a fake data source and writes a
# PNG so the tab bar's visual style can be verified without a GUI session.
if(BUILD_TESTING)
  add_executable(render_tabbar ${CMAKE_CURRENT_SOURCE_DIR}/../../Testing/render_tabbar.mm)
  target_link_libraries(render_tabbar PRIVATE
    DocumentWindow Find HTMLOutputWindow MenuBuilder OakAppKit OakFilterList OakFoundation OakSystem Preferences authorization bundles cf command crash document io ns plist regexp scm settings text theme
    ${TEXTMATE_DEBUG_LIBS})
endif()
