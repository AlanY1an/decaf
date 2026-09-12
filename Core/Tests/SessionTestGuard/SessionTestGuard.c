#include "SessionTestGuard.h"
#include <sandbox.h>
#include <pwd.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// Linked into tests ONLY. The constructor runs before any XCTest fixture.
// A kernel-enforced profile survives HOME changes, leaked threads, Swift error
// handling and child processes. There is no reset or disarm API. Failure to
// install terminates the test process; it cannot become a skipped green test.
static int installed;
static char real_home[PATH_MAX];
static char probe_parent[PATH_MAX];
static char probe_path[PATH_MAX];
static char profile[65536] = "(version 1)(allow default)";

static void append(const char *s) {
    if (strlen(profile) + strlen(s) + 1 >= sizeof(profile)) _exit(78);
    strcat(profile, s);
}

static void deny_path(const char *path) {
    if (!path || path[0] != '/') _exit(78);
    append("(deny file-write* (subpath \"");
    for (const unsigned char *p = (const unsigned char *)path; *p; ++p) {
        if (*p < 32 || *p == 127) _exit(78);
        if (*p == '\\' || *p == '"') append("\\");
        char c[2] = {(char)*p, 0}; append(c);
    }
    append("\"))");
    // Also protect the canonical target when a production root is linked.
    char resolved[PATH_MAX];
    if (realpath(path, resolved) && strcmp(path, resolved)) deny_path(resolved);
}

static void protect_home(const char *home) {
    if (!home || !home[0]) return;
    const char *suffixes[] = {"/.claude", "/.claude.json", "/.claude.json.backup",
        "/.decaf", "/.local/share/decaf", "/.config/decaf",
        "/Library/Application Support/Claude", "/Library/Application Support/Decaf",
        "/Library/Preferences/io.github.alany1an.decaf.plist", NULL};
    for (int i = 0; suffixes[i]; ++i) {
        char path[PATH_MAX];
        if (snprintf(path, sizeof(path), "%s%s", home, suffixes[i]) >= sizeof(path)) _exit(78);
        deny_path(path);
    }
}

__attribute__((constructor)) static void install_guard(void) {
    struct passwd *entry = getpwuid(getuid());
    if (!entry || !entry->pw_dir) _exit(78);
    if (strlcpy(real_home, entry->pw_dir, sizeof(real_home)) >= sizeof(real_home)) _exit(78);
    protect_home(real_home);             // HOME/config cleared resolution
    protect_home(getenv("HOME"));         // ambient resolution, frozen now
    const char *config = getenv("CLAUDE_CONFIG_DIR");
    if (config && config[0]) deny_path(config);
    deny_path("/Applications/Claude.app");
    // An independent, existing parent makes the denial probe deterministic on
    // clean CI Macs without ~/.claude. Protect it through the very same rule as
    // live stores; no probe ever needs to create a file inside those stores.
    char temp[PATH_MAX];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, temp, sizeof(temp));
    if (!length || length > sizeof(temp)) _exit(78);
    if (snprintf(probe_parent, sizeof(probe_parent), "%s/decaf-session-guard.XXXXXX", temp) >= sizeof(probe_parent)) _exit(78);
    if (!mkdtemp(probe_parent)) _exit(78);
    char canonical_parent[PATH_MAX];
    if (!realpath(probe_parent, canonical_parent)) _exit(78);
    if (strlcpy(probe_parent, canonical_parent, sizeof(probe_parent)) >= sizeof(probe_parent)) _exit(78);
    if (snprintf(probe_path, sizeof(probe_path), "%s/probe", probe_parent) >= sizeof(probe_path)) _exit(78);
    deny_path(probe_path);
    char *error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (sandbox_init(profile, 0, &error) != 0) {
        fprintf(stderr, "Decaf session test guard could not start: %s\n", error ? error : "unknown");
        _exit(78);
    }
#pragma clang diagnostic pop
    installed = 1;
}

int decaf_session_test_guard_installed(void) { return installed; }
const char *decaf_session_test_probe_path(void) { return probe_path; }

__attribute__((destructor)) static void remove_probe_parent(void) {
    // Only the nonexistent child is protected. Removing this empty, test-owned
    // parent is allowed; a failed probe leaves evidence instead of deleting it.
    if (probe_parent[0]) rmdir(probe_parent);
}
