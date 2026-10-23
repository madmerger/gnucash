# CMakeLists.txt for common/

# The subdirectories
add_subdirectory (cmake_modules)
add_subdirectory (debug)
add_subdirectory (test-core)

set(common_EXTRA_DIST
        base-typemaps.i
        config.h.cmake.in
        gnc-test-env.pl
        guile-mappings.h
        platform.h)


set (SWIG_RUNTIME_H ${CMAKE_CURRENT_BINARY_DIR}/swig-runtime.h)
set (SWIG_LLP64_FIX ${CMAKE_CURRENT_SOURCE_DIR}/cmake_modules/GncFixSwigGuileLLP64.cmake)
# Command to generate the swig-runtime.h header
add_custom_command (
    OUTPUT ${SWIG_RUNTIME_H}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/CMakeLists.txt ${SWIG_LLP64_FIX}
    COMMAND ${SWIG_EXECUTABLE} -guile -external-runtime ${SWIG_RUNTIME_H}
    COMMAND ${CMAKE_COMMAND} "-DSWIG_FILE=${SWIG_RUNTIME_H}" -DREQUIRE_POINTER_ADDRESS=ON -P ${SWIG_LLP64_FIX}
)
add_custom_target (swig-runtime-h DEPENDS ${SWIG_RUNTIME_H})

set_local_dist(common_DIST_local CMakeLists.txt ${common_EXTRA_DIST})

set(common_DIST ${common_DIST_local} ${cmake_modules_DIST} ${debug_DIST} ${test_core_DIST} PARENT_SCOPE)
