// bowser-cef Helper: the executable for CEF's child processes (renderer, GPU,
// utility). One binary serves every helper app in the bundle.
//
// The macOS sandbox must be entered before the CEF framework loads, so this
// process can't link the framework. It loads libcef_sandbox and the framework
// at runtime and looks up the two functions it needs.
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"

// Helpers live in <main>.app/Contents/Frameworks/<helper>.app/Contents/MacOS.
#define FRAMEWORK_DIR "/../../../Chromium Embedded Framework.framework"

static void *open_relative(const char *dir, const char *rel) {
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s%s", dir, rel);
  void *h = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!h) fprintf(stderr, "bowser-cef helper: %s\n", dlerror());
  return h;
}

int main(int argc, char **argv) {
  char exe[PATH_MAX];
  uint32_t len = sizeof exe;
  if (_NSGetExecutablePath(exe, &len) != 0) return 1;
  *strrchr(exe, '/') = 0;

  void *sandbox = open_relative(exe, FRAMEWORK_DIR "/Libraries/libcef_sandbox.dylib");
  void *(*sandbox_initialize)(int, char **) = sandbox ? dlsym(sandbox, "cef_sandbox_initialize") : NULL;
  if (!sandbox_initialize || !sandbox_initialize(argc, argv)) return 1;

  void *cef = open_relative(exe, FRAMEWORK_DIR "/Chromium Embedded Framework");
  if (!cef) return 1;
  const char *(*api_hash)(int, int) = dlsym(cef, "cef_api_hash");
  int (*execute_process)(const cef_main_args_t *, cef_app_t *, void *) = dlsym(cef, "cef_execute_process");
  if (!api_hash || !execute_process) return 1;

  api_hash(CEF_API_VERSION, 0); // must be the first CEF call in every process
  cef_main_args_t args = {argc, argv};
  return execute_process(&args, NULL, NULL);
}
