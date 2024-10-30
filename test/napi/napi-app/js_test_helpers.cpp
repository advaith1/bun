#include "js_test_helpers.h"

#include "utils.h"
#include <map>
#include <string>

namespace napitests {

static bool finalize_called = false;

static void finalize_cb(napi_env env, void *finalize_data,
                        void *finalize_hint) {
  // only do this in bun
  bool &create_handle_scope = *reinterpret_cast<bool *>(finalize_hint);
  if (create_handle_scope) {
    napi_handle_scope hs;
    NODE_API_CALL_CUSTOM_RETURN(env, void(), napi_open_handle_scope(env, &hs));
    NODE_API_CALL_CUSTOM_RETURN(env, void(), napi_close_handle_scope(env, hs));
  }
  delete &create_handle_scope;
  finalize_called = true;
}

static napi_value create_ref_with_finalizer(const Napi::CallbackInfo &info) {
  napi_env env = info.Env();
  napi_value create_handle_scope_in_finalizer = info[0];

  napi_value object;
  NODE_API_CALL(env, napi_create_object(env, &object));

  bool *finalize_hint = new bool;
  NODE_API_CALL(env, napi_get_value_bool(env, create_handle_scope_in_finalizer,
                                         finalize_hint));

  napi_ref ref;

  NODE_API_CALL(env, napi_wrap(env, object, nullptr, finalize_cb,
                               reinterpret_cast<bool *>(finalize_hint), &ref));

  return ok(env);
}

static napi_value was_finalize_called(const Napi::CallbackInfo &info) {
  napi_value ret;
  NODE_API_CALL(info.Env(),
                napi_get_boolean(info.Env(), finalize_called, &ret));
  return ret;
}

// calls a function (the sole argument) which must throw. catches and returns
// the thrown error
static napi_value call_and_get_exception(const Napi::CallbackInfo &info) {
  napi_env env = info.Env();
  napi_value fn = info[0];
  napi_value undefined;
  NODE_API_CALL(env, napi_get_undefined(env, &undefined));

  NODE_API_ASSERT(env, napi_call_function(env, undefined, fn, 0, nullptr,
                                          nullptr) == napi_pending_exception);

  bool is_pending;
  NODE_API_CALL(env, napi_is_exception_pending(env, &is_pending));
  NODE_API_ASSERT(env, is_pending);

  napi_value exception;
  NODE_API_CALL(env, napi_get_and_clear_last_exception(env, &exception));

  napi_valuetype type = get_typeof(env, exception);
  printf("typeof thrown exception = %s\n", napi_valuetype_to_string(type));

  NODE_API_CALL(env, napi_is_exception_pending(env, &is_pending));
  NODE_API_ASSERT(env, !is_pending);

  return exception;
}

// throw_error(code: string|undefined, msg: string|undefined,
// error_kind: 'error'|'type_error'|'range_error'|'syntax_error')
// if code and msg are JS undefined then change them to nullptr
static napi_value throw_error(const Napi::CallbackInfo &info) {
  napi_env env = info.Env();

  Napi::Value js_code = info[0];
  Napi::Value js_msg = info[1];
  std::string error_kind = info[2].As<Napi::String>().Utf8Value();

  // these are optional
  const char *code = nullptr;
  std::string code_str;
  const char *msg = nullptr;
  std::string msg_str;

  if (js_code.IsString()) {
    code_str = js_code.As<Napi::String>().Utf8Value();
    code = code_str.c_str();
  }
  if (js_msg.IsString()) {
    msg_str = js_msg.As<Napi::String>().Utf8Value();
    msg = msg_str.c_str();
  }

  using ThrowFunction =
      napi_status (*)(napi_env, const char *code, const char *msg);
  std::map<std::string, ThrowFunction> functions{
      {"error", napi_throw_error},
      {"type_error", napi_throw_type_error},
      {"range_error", napi_throw_range_error},
      {"syntax_error", node_api_throw_syntax_error}};

  auto throw_function = functions[error_kind];

  if (msg == nullptr) {
    NODE_API_ASSERT(env, throw_function(env, code, msg) == napi_invalid_arg);
    return ok(env);
  } else {
    NODE_API_ASSERT(env, throw_function(env, code, msg) == napi_ok);
    return nullptr;
  }
}

// create_and_throw_error(code: any, msg: any,
// error_kind: 'error'|'type_error'|'range_error'|'syntax_error')
// if code and msg are JS null then change them to nullptr
static napi_value create_and_throw_error(const Napi::CallbackInfo &info) {
  napi_env env = info.Env();

  napi_value js_code = info[0];
  napi_value js_msg = info[1];
  std::string error_kind = info[2].As<Napi::String>();

  if (get_typeof(env, js_code) == napi_null) {
    js_code = nullptr;
  }
  if (get_typeof(env, js_msg) == napi_null) {
    js_msg = nullptr;
  }

  using CreateErrorFunction = napi_status (*)(
      napi_env, napi_value code, napi_value msg, napi_value *result);
  std::map<std::string, CreateErrorFunction> functions{
      {"error", napi_create_error},
      {"type_error", napi_create_type_error},
      {"range_error", napi_create_range_error},
      {"syntax_error", node_api_create_syntax_error}};

  auto create_error_function = functions[error_kind];

  napi_value err;
  napi_status create_status = create_error_function(env, js_code, js_msg, &err);
  // cases that should fail:
  // - js_msg is nullptr
  // - js_msg is not a string
  // - js_code is not nullptr and not a string
  // also we need to make sure not to call get_typeof with nullptr, since it
  // asserts that napi_typeof succeeded
  if (!js_msg || get_typeof(env, js_msg) != napi_string ||
      (js_code && get_typeof(env, js_code) != napi_string)) {
    // bun and node may return different errors here depending on in what order
    // the parameters are checked, but what's important is that there is an
    // error
    NODE_API_ASSERT(env, create_status == napi_string_expected ||
                             create_status == napi_invalid_arg);
    return ok(env);
  } else {
    NODE_API_ASSERT(env, create_status == napi_ok);
    NODE_API_CALL(env, napi_throw(env, err));
    return nullptr;
  }
}

// perform_get(object, key)
static napi_value perform_get(const Napi::CallbackInfo &info) {
  napi_env env = info.Env();
  napi_value obj = info[0];
  napi_value key = info[1];
  napi_status status;
  napi_value value;

  // if key is a string, try napi_get_named_property
  napi_valuetype type = get_typeof(env, key);
  if (type == napi_string) {
    char buf[1024];
    NODE_API_CALL(env,
                  napi_get_value_string_utf8(env, key, buf, 1024, nullptr));
    status = napi_get_named_property(env, obj, buf, &value);
    if (status == napi_ok) {
      NODE_API_ASSERT(env, value != nullptr);
      printf("value type = %d\n", get_typeof(env, value));
    } else {
      NODE_API_ASSERT(env, status == napi_pending_exception);
      return ok(env);
    }
  }

  status = napi_get_property(env, obj, key, &value);
  NODE_API_ASSERT(env, status == napi_pending_exception);
  if (status == napi_ok) {
    NODE_API_ASSERT(env, value != nullptr);
    printf("value type = %d\n", get_typeof(env, value));
    return value;
  } else {
    return ok(env);
  }
}

static napi_value make_empty_array(const Napi::CallbackInfo &info) {
  napi_env env = info.Env();
  napi_value js_size = info[0];
  uint32_t size;
  NODE_API_CALL(env, napi_get_value_uint32(env, js_size, &size));
  napi_value array;
  NODE_API_CALL(env, napi_create_array_with_length(env, size, &array));
  return array;
}

// add_tag(object, lower, upper)
static napi_value add_tag(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  napi_value object = info[0];

  uint32_t lower, upper;
  NODE_API_CALL(env, napi_get_value_uint32(env, info[1], &lower));
  NODE_API_CALL(env, napi_get_value_uint32(env, info[2], &upper));
  napi_type_tag tag = {.lower = lower, .upper = upper};
  NODE_API_CALL(env, napi_type_tag_object(env, object, &tag));
  return env.Undefined();
}

// check_tag(object, lower, upper): bool
static napi_value check_tag(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  napi_value object = info[0];

  uint32_t lower, upper;
  NODE_API_CALL(env, napi_get_value_uint32(env, info[1], &lower));
  NODE_API_CALL(env, napi_get_value_uint32(env, info[2], &upper));

  napi_type_tag tag = {.lower = lower, .upper = upper};
  bool matches;
  NODE_API_CALL(env, napi_check_object_type_tag(env, object, &tag, &matches));
  return Napi::Boolean::New(env, matches);
}

void register_js_test_helpers(Napi::Env env, Napi::Object exports) {
  REGISTER_FUNCTION(env, exports, create_ref_with_finalizer);
  REGISTER_FUNCTION(env, exports, was_finalize_called);
  REGISTER_FUNCTION(env, exports, call_and_get_exception);
  REGISTER_FUNCTION(env, exports, perform_get);
  REGISTER_FUNCTION(env, exports, throw_error);
  REGISTER_FUNCTION(env, exports, create_and_throw_error);
  REGISTER_FUNCTION(env, exports, make_empty_array);
  REGISTER_FUNCTION(env, exports, add_tag);
  REGISTER_FUNCTION(env, exports, check_tag);
}

} // namespace napitests