// Launch a program inside sandbox.sb, keeping DYLD_* variables.
// (sandbox-exec is a platform binary, so dyld strips DYLD_* before its child
// runs. A sandbox applied here survives execv, and so does the environment.)
//
// Usage: launch <profile.sb> <program> [args...]
#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[],
                                 char **errorbuf);

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <profile.sb> <program> [args...]\n", argv[0]);
    return 2;
  }
  FILE *f = fopen(argv[1], "r");
  if (!f) {
    perror(argv[1]);
    return 1;
  }
  static char profile[1 << 16];
  size_t n = fread(profile, 1, sizeof profile - 1, f);
  fclose(f);
  profile[n] = 0;

  // The profile guards the real home, whatever $HOME says.
  const char *home = getpwuid(getuid())->pw_dir;
  const char *params[] = {"HOME", home, NULL};
  char *err = NULL;
  if (sandbox_init_with_parameters(profile, 0, params, &err) != 0) {
    fprintf(stderr, "sandbox: %s\n", err ? err : "failed");
    return 1;
  }
  execv(argv[2], argv + 2);
  fprintf(stderr, "exec %s: %s\n", argv[2], strerror(errno));
  return 1;
}
