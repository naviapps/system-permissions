#include <CSystemPermissions/system_permissions.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void copy_result(SystemPermissionsResult *result, uint32_t status, char *response,
                        size_t capacity) {
    assert(result != NULL && system_permissions_result_status(result) == status);
    const uint8_t *bytes = system_permissions_result_data(result);
    size_t length = system_permissions_result_len(result);
    assert(bytes != NULL && length < capacity);
    memcpy(response, bytes, length);
    response[length] = '\0';
    system_permissions_result_free(result);
}

static void copy_response(const char *request, uint32_t status, char *response, size_t capacity) {
    copy_result(system_permissions_call((const uint8_t *)request, strlen(request)), status,
                response, capacity);
}

static void copy_store_response(SystemPermissionsStore *store, const char *request, char *response,
                                size_t capacity) {
    copy_result(system_permissions_store_call(store, (const uint8_t *)request, strlen(request)), 0,
                response, capacity);
}

int main(void) {
    char response[128];
    copy_response("{\"op\":\"storeBatchLimit\"}", 0, response, sizeof response);
    assert(strcmp(response, "1024") == 0);
    const char *notifications =
        "{\"op\":\"validateOptions\",\"permission\":{\"id\":\"notifications\"},"
        "\"options\":{\"kind\":\"notifications\",\"notificationOptions\":18446744073709551615}}";
    copy_response(notifications, 0, response, sizeof response);
    assert(strstr(response, "\"kind\":\"notifications\"") != NULL);
    assert(strstr(response, "\"notificationOptions\":18446744073709551615") != NULL);

    copy_response(
        "{\"op\":\"admitAccess\",\"platform\":\"macos\",\"request\":false,"
        "\"permission\":{\"id\":\"notifications\"},"
        "\"options\":{\"kind\":\"notifications\",\"notificationOptions\":18446744073709551615}}",
        0, response, sizeof response);
    assert(strcmp(response, "{\"options\":{\"kind\":\"notifications\","
                            "\"notificationOptions\":18446744073709551615}}") == 0);

    const char *camera = "{\"op\":\"validateOptions\",\"permission\":{\"id\":\"camera\"},"
                         "\"options\":{\"kind\":\"notifications\",\"notificationOptions\":5}}";
    copy_response(camera, 1, response, sizeof response);
    assert(strcmp(response, "{\"error\":\"invalidOptions\"}") == 0);
    copy_response(
        "{\"op\":\"admitSettings\",\"platform\":\"macos\",\"permission\":{\"id\":\"camera\"},"
        "\"options\":{\"kind\":\"photos\",\"photoAccessLevel\":\"addOnly\"}}",
        0, response, sizeof response);
    assert(strcmp(response, "{\"result\":{\"error\":\"invalidOptions\",\"kind\":\"failed\"}}") ==
           0);
    SystemPermissionsStore *store = system_permissions_store_new();
    assert(store != NULL);
    char tracked[256];
    copy_store_response(store, "{\"op\":\"track\",\"permissions\":[{\"id\":\"camera\"}]}", tracked,
                        sizeof tracked);
    copy_store_response(
        store, "{\"op\":\"admit\",\"permission\":{\"id\":\"camera\"},\"kind\":\"request\"}",
        response, sizeof response);
    assert(strcmp(response, "{\"token\":1}") == 0);
    const char *malformed[] = {
        "{\"op\":\"track\",\"permissions\":[[\"microphone\"]]}",
        "{\"op\":\"apply\",\"updates\":[[{\"id\":\"camera\"},1,{\"kind\":\"supported\","
        "\"value\":\"denied\"}]],\"cancelled\":false}",
    };
    for (size_t i = 0; i < sizeof malformed / sizeof malformed[0]; ++i) {
        const char *request = malformed[i];
        copy_result(system_permissions_store_call(store, (const uint8_t *)request, strlen(request)),
                    1, response, sizeof response);
        assert(strcmp(response, "{\"error\":\"invalidJson\"}") == 0);
    }
    char retained[256];
    copy_store_response(store, "{\"op\":\"snapshot\"}", retained, sizeof retained);
    assert(strcmp(retained, tracked) == 0);
    copy_store_response(store,
                        "{\"op\":\"admitScoped\",\"permission\":{\"id\":\"camera\"},"
                        "\"options\":{\"kind\":\"photos\",\"photoAccessLevel\":\"addOnly\"},"
                        "\"kind\":\"request\",\"cancelled\":false}",
                        response, sizeof response);
    assert(strcmp(response, "{\"kind\":\"invalidOptions\"}") == 0);
    copy_store_response(
        store, "{\"op\":\"admit\",\"permission\":{\"id\":\"camera\"},\"kind\":\"refresh\"}",
        response, sizeof response);
    assert(strcmp(response, "{\"token\":null}") == 0);
    copy_store_response(store, "{\"op\":\"finish\",\"token\":1}", response, sizeof response);
    assert(strcmp(response, "{\"finished\":true}") == 0);
    copy_store_response(
        store, "{\"op\":\"admit\",\"permission\":{\"id\":\"camera\"},\"kind\":\"refresh\"}",
        response, sizeof response);
    assert(strcmp(response, "{\"token\":2}") == 0);
    system_permissions_store_free(store);
    puts("Standalone installed C SystemPermissions consumer passed owned responses, validation and "
         "work admission.");
    return 0;
}
