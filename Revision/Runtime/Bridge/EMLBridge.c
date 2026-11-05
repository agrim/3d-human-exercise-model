#include "EMLBridge.h"
// The distributed CPython headers use quoted imports internally.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#include <Python/Python.h>
#pragma clang diagnostic pop
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <mach-o/dyld.h>

void EMLRelease(void *ptr) { free(ptr); }

static char *exceptionMessage(void) {
    PyObject *exception = PyErr_GetRaisedException();
    PyObject *message = exception ? PyObject_Str(exception) : NULL;
    const char *detail = message ? PyUnicode_AsUTF8(message) : NULL;
    char *result = strdup(detail ? detail : "The EML compiler could not start.");
    Py_XDECREF(message);
    Py_XDECREF(exception);
    PyErr_Clear();
    return result;
}

static PyStatus addPath(PyConfig *config, const char *bundle, const char *relative) {
    char *path = NULL;
    if (asprintf(&path, "%s/%s", bundle, relative) < 0) return PyStatus_NoMemory();
    wchar_t *wide = Py_DecodeLocale(path, NULL);
    free(path);
    if (!wide) return PyStatus_NoMemory();
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide);
    PyMem_RawFree(wide);
    return status;
}

// Called exclusively on the bridge's serial queue. CPython stays alive for the app's lifetime.
static int initialize(const char *bundle, char **error) {
    if (Py_IsInitialized()) return 0;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.site_import = 0;
    config.module_search_paths_set = 1;
    char *home = NULL;
    if (asprintf(&home, "%s/python", bundle) < 0) {
        *error = strdup("Not enough memory to initialize the compiler.");
        PyConfig_Clear(&config);
        return -1;
    }
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
    free(home);
    // The CPython AppleFrameworkLoader resolves signed module paths from sys.executable.
    uint32_t capacity = 0;
    _NSGetExecutablePath(NULL, &capacity);
    char *appPath = malloc(capacity);
    if (!PyStatus_Exception(status)) {
        if (!appPath || _NSGetExecutablePath(appPath, &capacity) != 0) status = PyStatus_NoMemory();
        else status = PyConfig_SetBytesString(&config, &config.executable, appPath);
    }
    free(appPath);
    const char *paths[] = { "python/lib/python313.zip", "python/lib/python3.13", "python/lib/python3.13/lib-dynload",
                            "python/packages", "EML" };
    for (size_t i = 0; i < sizeof(paths) / sizeof(*paths) && !PyStatus_Exception(status); i++)
        status = addPath(&config, bundle, paths[i]);
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) *error = strdup(status.err_msg ? status.err_msg : "Python initialization failed.");
    PyConfig_Clear(&config);
    if (*error) return -1;
    PyEval_SaveThread();
    return 0;
}

int EMLCompile(const char *bundle, const uint8_t *source, size_t sourceSize, int strict,
               uint8_t **output, size_t *outputSize, char **error) {
    *output = NULL; *outputSize = 0; *error = NULL;
    if (initialize(bundle, error) != 0) return -1;
    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("eml_mobile");
    PyObject *method = module ? PyObject_GetAttrString(module, "compile_bytes") : NULL;
    PyObject *input = method ? PyBytes_FromStringAndSize((const char *)source, (Py_ssize_t)sourceSize) : NULL;
    PyObject *result = input ? PyObject_CallFunctionObjArgs(method, input, strict ? Py_True : Py_False, NULL) : NULL;
    char *bytes = NULL;
    Py_ssize_t length = 0;
    if (!result || PyBytes_AsStringAndSize(result, &bytes, &length) < 0) {
        *error = exceptionMessage();
    } else if (!(*output = malloc((size_t)length))) {
        *error = strdup("Not enough memory for the compiled movement.");
    } else {
        memcpy(*output, bytes, (size_t)length);
        *outputSize = (size_t)length;
    }
    Py_XDECREF(result); Py_XDECREF(input); Py_XDECREF(method); Py_XDECREF(module);
    PyGILState_Release(state);
    return *output ? 0 : -1;
}
