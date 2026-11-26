#include "zygisk.hpp"
#include "asb_screenshot_filter.h"
#include <cstdint>
#include <cstring>

namespace {
using Transact = jboolean (*)(JNIEnv *, jobject, jint, jobject, jobject, jint);
Transact original_transact = nullptr;
jmethodID get_position = nullptr, set_position = nullptr, get_size = nullptr;
jmethodID read_int = nullptr, write_int = nullptr, read_string = nullptr;
jint window_transactions[8]{};
unsigned transaction_count = 0;

bool clean(JNIEnv *env) {
    if (!env->ExceptionCheck()) return true;
    env->ExceptionClear();
    return false;
}
bool window_transaction(jint code) {
    for (unsigned i = 0; i < transaction_count; ++i) if (window_transactions[i] == code) return true;
    return false;
}

// Inspect a possible interface token without interpreting an arbitrary Parcel
// string length. The caller restores dataPosition before returning.
bool interface_at(JNIEnv *env, jobject parcel, jint offset, jint size, jint &end) {
    static constexpr char name[] = "android.view.IWindowSession";
    constexpr jint chars = sizeof(name) - 1;
    if (offset < 0 || size < offset || size - offset < 4 + 2 * (chars + 1)) return false;
    env->CallVoidMethod(parcel, set_position, offset);
    if (!clean(env)) return false;
    const jint actual_length = env->CallIntMethod(parcel, read_int);
    if (!clean(env) || actual_length != chars) return false;
    env->CallVoidMethod(parcel, set_position, offset);
    if (!clean(env)) return false;
    jstring value = static_cast<jstring>(env->CallObjectMethod(parcel, read_string));
    if (!clean(env) || !value) return false;
    const char *text = env->GetStringUTFChars(value, nullptr);
    const bool ok = text && asb_screenshot::is_window_session(text);
    if (text) env->ReleaseStringUTFChars(value, text);
    env->DeleteLocalRef(value);
    if (!clean(env) || !ok) return false;
    end = env->CallIntMethod(parcel, get_position);
    return clean(env) && end >= 0 && end <= size;
}

void adjust_window(JNIEnv *env, jobject parcel, jint code) {
    if (!parcel || !window_transaction(code) || env->ExceptionCheck()) return;
    const jint saved = env->CallIntMethod(parcel, get_position);
    if (!clean(env)) return;
    const jint size = env->CallIntMethod(parcel, get_size);
    if (!clean(env) || size < 0 || size > 1024 * 1024) return;
    jint token_end = -1;
    const bool identified = interface_at(env, parcel, 4, size, token_end) ||
                            interface_at(env, parcel, 12, size, token_end);
    if (identified && token_end <= size - 56) {
        // SDK 37, 64-bit binder object followed by the typed-object marker.
        env->CallVoidMethod(parcel, set_position, token_end + 28);
        bool marker = false;
        if (clean(env)) {
            const jint value = env->CallIntMethod(parcel, read_int);
            marker = clean(env) && value == 1;
        }
        if (marker) {
            asb_screenshot::WindowFields w{};
            int32_t *values[] = {&w.width, &w.height, &w.x, &w.y, &w.type, &w.flags};
            bool complete = true;
            for (auto value : values) {
                *value = env->CallIntMethod(parcel, read_int);
                if (!clean(env)) { complete = false; break; }
            }
            if (complete && asb_screenshot::candidate(w)) {
                env->CallVoidMethod(parcel, set_position, token_end + 52);
                if (clean(env)) { env->CallVoidMethod(parcel, write_int, asb_screenshot::filtered(w.flags)); clean(env); }
            }
        }
    }
    env->CallVoidMethod(parcel, set_position, saved);
    clean(env);
}

jboolean wrapped_transact(JNIEnv *env, jobject self, jint code, jobject data, jobject reply, jint flags) {
    if (original_transact) {
        adjust_window(env, data, code);
        return original_transact(env, self, code, data, reply, flags);
    }
    return JNI_FALSE;
}
}

// Called after specialize only in an explicitly selected regular app process.
bool asb_screenshot_install(zygisk::Api *api, JNIEnv *env) {
    if (!api || !env || env->ExceptionCheck() || !api->supportsJniHooks()) return false;
    jclass build = env->FindClass("android/os/Build$VERSION");
    if (!clean(env) || !build) return false;
    jfieldID sdk_field = env->GetStaticFieldID(build, "SDK_INT", "I");
    if (!clean(env) || !sdk_field) { env->DeleteLocalRef(build); return false; }
    const jint sdk = env->GetStaticIntField(build, sdk_field);
    env->DeleteLocalRef(build);
    if (!clean(env) || !asb_screenshot::supported(sdk, sizeof(void *))) return false;

    jclass session = env->FindClass("android/view/IWindowSession$Stub");
    if (!clean(env) || !session) return false;
    const char *fields[] = {"TRANSACTION_addToDisplay", "TRANSACTION_addToDisplayAsUser",
        "TRANSACTION_addToDisplayWithoutInputChannel", "TRANSACTION_relayout", "TRANSACTION_relayoutAsync"};
    transaction_count = 0;
    for (const char *field : fields) {
        jfieldID id = env->GetStaticFieldID(session, field, "I");
        if (!clean(env) || !id) continue;
        const jint value = env->GetStaticIntField(session, id);
        if (clean(env) && value > 0) window_transactions[transaction_count++] = value;
    }
    env->DeleteLocalRef(session);
    if (!transaction_count) return false;

    jclass parcel = env->FindClass("android/os/Parcel");
    if (!clean(env) || !parcel) return false;
    auto lookup = [env, parcel](const char *name, const char *signature) -> jmethodID {
        jmethodID id = env->GetMethodID(parcel, name, signature);
        return clean(env) ? id : nullptr;
    };
    get_position = lookup("dataPosition", "()I");
    set_position = lookup("setDataPosition", "(I)V");
    get_size = lookup("dataSize", "()I");
    read_int = lookup("readInt", "()I");
    write_int = lookup("writeInt", "(I)V");
    read_string = lookup("readString", "()Ljava/lang/String;");
    const bool ready = get_position && set_position && get_size && read_int && write_int && read_string;
    env->DeleteLocalRef(parcel);
    if (!ready) return false;
    JNINativeMethod methods[] = {{const_cast<char *>("transactNative"),
        const_cast<char *>("(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z"), reinterpret_cast<void *>(&wrapped_transact)}};
    api->hookJniNativeMethods(env, "android/os/BinderProxy", methods, 1);
    if (!clean(env) || !methods[0].fnPtr || methods[0].fnPtr == reinterpret_cast<void *>(&wrapped_transact)) return false;
    original_transact = reinterpret_cast<Transact>(methods[0].fnPtr);
    return true;
}
