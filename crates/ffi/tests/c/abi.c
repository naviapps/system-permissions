#include "system_permissions.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <appmodel.h>
#include <wchar.h>
#endif

static void expect(SystemPermissionsResult *result, uint32_t status, const char *text) {
    assert(result != NULL);
    assert(system_permissions_result_status(result) == status);
    size_t length = system_permissions_result_len(result);
    const uint8_t *data = system_permissions_result_data(result);
    assert(data != NULL);
    assert(length == strlen(text));
    assert(memcmp(data, text, length) == 0);
    system_permissions_result_free(result);
}
static SystemPermissionsResult *call(const char *text) {
    return system_permissions_call((const uint8_t *)text, strlen(text));
}
static SystemPermissionsResult *store_call(SystemPermissionsStore *store, const char *text) {
    return system_permissions_store_call(store, (const uint8_t *)text, strlen(text));
}

static char *copy_result(SystemPermissionsResult *result, uint32_t status) {
    assert(result != NULL);
    assert(system_permissions_result_status(result) == status);
    size_t count = system_permissions_result_len(result);
    const uint8_t *data = system_permissions_result_data(result);
    assert(data != NULL);
    char *copy = malloc(count + 1);
    assert(copy != NULL);
    memcpy(copy, data, count);
    copy[count] = '\0';
    return copy;
}

static void test_contract(void) {
    assert(system_permissions_abi_version() == SYSTEM_PERMISSIONS_ABI_VERSION);
    assert(system_permissions_result_status(NULL) == 1);
    assert(system_permissions_result_data(NULL) == NULL);
    assert(system_permissions_result_len(NULL) == 0);
    system_permissions_result_free(NULL);
    system_permissions_store_free(NULL);
    expect(system_permissions_call(NULL, 0), 1, "{\"error\":\"invalidBuffer\"}");
    expect(system_permissions_call(NULL, 1024 * 1024 + 1), 1, "{\"error\":\"inputTooLarge\"}");
    const uint8_t invalid_utf8[] = {0xff};
    expect(system_permissions_call(invalid_utf8, sizeof invalid_utf8), 1,
           "{\"error\":\"invalidUtf8\"}");
    expect(call("{}"), 1, "{\"error\":\"invalidJson\"}");
    expect(call("{\"op\":\"admitAccess\",\"platform\":\"macos\",\"request\":true,"
                "\"permission\":{\"id\":\"notifications\"}}"),
           0, "{\"options\":{\"kind\":\"notifications\",\"notificationOptions\":7}}");
    expect(call("{\"op\":\"admitAccess\",\"platform\":\"macos\",\"request\":true,"
                "\"permission\":{\"id\":\"notifications\"},\"options\":{\"kind\":\"none\"}}"),
           0, "{\"options\":{\"kind\":\"none\"}}");
    expect(call("{\"op\":\"validateDescriptor\",\"permission\":{\"id\":\"camera\"}}"), 0,
           "{\"id\":\"camera\"}");
    expect(call("{\"op\":\"validateDescriptor\",\"permission\":[\"camera\"]}"), 1,
           "{\"error\":\"invalidJson\"}");
    expect(call("{\"op\":\"validateDescriptor\",\"permission\":{\"id\":\"camera\",\"id\":"
                "\"microphone\"}}"),
           1, "{\"error\":\"invalidJson\"}");
    expect(call("{\"op\":\"validateSettingsResult\",\"result\":{\"kind\":\"supported\",\"value\":"
                "true}}"),
           0, "{\"kind\":\"supported\",\"value\":true}");
    expect(call("{\"op\":\"validateOptions\",\"permission\":{\"id\":\"notifications\"},\"options\":"
                "{\"kind\":\"notifications\",\"notificationOptions\":18446744073709551615}}"),
           0, "{\"kind\":\"notifications\",\"notificationOptions\":18446744073709551615}");

    SystemPermissionsStore *changed = system_permissions_store_new();
    SystemPermissionsResult *prior = store_call(
        changed, "{\"op\":\"track\",\"permissions\":[{\"id\":\"camera\"},{\"id\":\"camera\"}]}");
    char *before = copy_result(prior, 0);
    expect(store_call(changed, "{\"op\":\"begin\",\"permission\":{\"id\":\"camera\"}}"), 0,
           "{\"token\":1}");
    expect(store_call(
               changed,
               "{\"op\":\"apply\",\"updates\":[{\"permission\":{\"id\":\"camera\"},\"token\":1,"
               "\"result\":{\"kind\":\"supported\",\"value\":\"granted\"}}],\"cancelled\":false}"),
           0, "{\"accepted\":1,\"changed\":true}");
    system_permissions_store_free(changed);
    char *after = copy_result(prior, 0);
    assert(strcmp(before, after) == 0);
    free(before);
    free(after);
    system_permissions_result_free(prior);

    SystemPermissionsStore *first = system_permissions_store_new();
    SystemPermissionsStore *second = system_permissions_store_new();
    assert(first != NULL && second != NULL && first != second);
    const char *track = "{\"op\":\"track\",\"permissions\":[{\"id\":\"camera\"}]}";
    SystemPermissionsResult *tracked = store_call(first, track);
    assert(system_permissions_result_status(tracked) == 0);
    size_t tracked_length = system_permissions_result_len(tracked);
    uint8_t *copy = malloc(tracked_length);
    assert(copy != NULL);
    memcpy(copy, system_permissions_result_data(tracked), tracked_length);
    expect(store_call(first,
                      "{\"op\":\"admit\",\"permission\":{\"id\":\"camera\"},\"kind\":\"refresh\"}"),
           0, "{\"token\":1}");
    expect(store_call(second, "{\"op\":\"get\",\"permission\":{\"id\":\"camera\"}}"), 0, "null");
    expect(store_call(
               first,
               "{\"op\":\"apply\",\"updates\":[{\"permission\":{\"id\":\"camera\"},\"token\":1,"
               "\"result\":{\"kind\":\"supported\",\"value\":\"granted\"}}],\"cancelled\":true}"),
           0, "{\"accepted\":0,\"changed\":false}");
    expect(store_call(first, "{\"op\":\"get\",\"permission\":{\"id\":\"camera\"}}"), 0,
           "{\"kind\":\"supported\",\"value\":\"unknown\"}");
    // Owned result views remain live across subsequent calls and store destruction.
    system_permissions_store_free(first);
    system_permissions_store_free(second);
    assert(system_permissions_result_len(tracked) == tracked_length);
    assert(memcmp(copy, system_permissions_result_data(tracked), tracked_length) == 0);
    system_permissions_result_free(tracked);
    free(copy);
    expect(store_call(NULL, "{\"op\":\"snapshot\"}"), 1, "{\"error\":\"invalidBuffer\"}");
    expect(call("{\"op\":\"allowsAccess\",\"status\":\"unknown\"}"), 0, "false");
    puts("C ownership, buffer boundaries and independent stores passed.");
}

#ifdef _WIN32
static void test_packaged_desktop(const wchar_t *expected) {
    wchar_t full_name[PACKAGE_FULL_NAME_MAX_LENGTH + 1];
    UINT32 length = PACKAGE_FULL_NAME_MAX_LENGTH + 1;
    assert(GetCurrentPackageFullName(&length, full_name) == ERROR_SUCCESS);
    assert(wcscmp(expected, full_name) == 0);

    expect(call("{\"op\":\"windowsRequest\",\"permission\":{\"id\":\"camera\"},\"options\":{"
                "\"kind\":\"none\"}}"),
           0,
           "{\"result\":{\"capability\":{\"requiresRelaunch\":false,\"supportsRequest\":false,"
           "\"supportsStatusCheck\":true,\"systemSettingsUrl\":\"ms-settings:privacy-webcam\"},"
           "\"kind\":\"unsupported\"}}");
    expect(call("{\"op\":\"admitSettings\",\"platform\":\"windows\",\"permission\":{\"id\":"
                "\"camera\"}}"),
           0,
           "{\"capability\":{\"requiresRelaunch\":false,\"supportsRequest\":false,"
           "\"supportsStatusCheck\":true,\"systemSettingsUrl\":\"ms-settings:privacy-webcam\"}}");

    SystemPermissionsResult *status = call("{\"op\":\"windowsStatus\",\"permission\":{\"id\":"
                                           "\"camera\"},\"options\":{\"kind\":\"none\"}}");
    char *result = copy_result(status, 0);
    assert(strcmp(result, "{\"error\":\"apiUnavailable\",\"kind\":\"failed\"}") == 0 ||
           strcmp(result, "{\"kind\":\"supported\",\"value\":\"granted\"}") == 0 ||
           strcmp(result, "{\"kind\":\"supported\",\"value\":\"denied\"}") == 0 ||
           strcmp(result, "{\"kind\":\"supported\",\"value\":\"restricted\"}") == 0 ||
           strcmp(result, "{\"kind\":\"supported\",\"value\":\"notDetermined\"}") == 0 ||
           strcmp(result, "{\"kind\":\"supported\",\"value\":\"unknown\"}") == 0);
    printf("MSIX desktop identity, unsupported direct consent, and Settings admission passed. "
           "Camera: %s\n",
           result);
    free(result);
    system_permissions_result_free(status);
}

int wmain(int argc, wchar_t **argv) {
    assert(argc == 1 || argc == 2);
    test_contract();
    if (argc == 2) {
        test_packaged_desktop(argv[1]);
    }
    return 0;
}
#else
int main(void) {
    test_contract();
    return 0;
}
#endif
