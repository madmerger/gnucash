if (NOT DEFINED SWIG_FILE OR NOT EXISTS "${SWIG_FILE}")
  message (FATAL_ERROR "SWIG_FILE must name an existing generated source file")
endif ()

file (READ "${SWIG_FILE}" swig_source)

if (REQUIRE_POINTER_ADDRESS)
  if (NOT swig_source MATCHES "SWIGINTERN unsigned long[ \t\r\n]+SWIG_Guile_PointerAddress")
    message (FATAL_ERROR "SWIG_Guile_PointerAddress no longer has the expected LLP64 signature in ${SWIG_FILE}")
  endif ()
endif ()

string (REGEX REPLACE "SWIGINTERN unsigned long[ \t\r\n]+SWIG_Guile_PointerAddress"
  "SWIGINTERN uintptr_t SWIG_Guile_PointerAddress" swig_source "${swig_source}")
string (REPLACE "(unsigned long) (void *) SCM_CELL_WORD_1"
  "(uintptr_t) (void *) SCM_CELL_WORD_1" swig_source "${swig_source}")
string (REPLACE "scm_from_ulong(" "scm_from_uintptr_t(" swig_source "${swig_source}")
string (REPLACE "scm_to_ulong(" "scm_to_uintptr_t(" swig_source "${swig_source}")
string (REPLACE "(unsigned long) swig_module" "(uintptr_t) swig_module"
  swig_source "${swig_source}")

if (swig_source MATCHES "uintptr_t" AND NOT swig_source MATCHES "#[ \t]*include[ \t]*<stdint\\.h>")
  string (PREPEND swig_source "#include <stdint.h>\n")
endif ()

file (WRITE "${SWIG_FILE}" "${swig_source}")
