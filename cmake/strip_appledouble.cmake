# Remove AppleDouble (._*) sidecar files from a bundle before codesigning.
# On exFAT/MS-DOS volumes the kernel stores extended attributes as these
# sidecars; codesign treats them as unsigned subcomponents and refuses.
# Usage: cmake -DBUNDLE_DIR=<path> -P strip_appledouble.cmake
if(NOT DEFINED BUNDLE_DIR OR NOT EXISTS "${BUNDLE_DIR}")
	return()
endif()
file(GLOB_RECURSE _appledouble_files LIST_DIRECTORIES true "${BUNDLE_DIR}/._*")
foreach(_file IN LISTS _appledouble_files)
	file(REMOVE "${_file}")
endforeach()
