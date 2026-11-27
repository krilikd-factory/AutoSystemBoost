#pragma once
#include <cstdarg>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
using jint = int32_t; using jlong = int64_t; using jboolean = uint8_t;
using jobject = void *; using jstring = void *; using jclass = void *;
using jintArray = void *; using jobjectArray = void *; using jfieldID = void *; using jmethodID = void *;
#define JNI_FALSE 0
struct JNINativeMethod { char *name; char *signature; void *fnPtr; };
struct FixtureParcel { std::vector<uint8_t> data; int pos = 0; };
struct JNIEnv {
  bool error = false; int reads = 0; std::string str;
  bool ExceptionCheck() { return error; }
  void ExceptionClear() { error = false; }
  jint CallIntMethod(jobject o, jmethodID id, ...) {
    auto *p = static_cast<FixtureParcel *>(o); auto k = reinterpret_cast<uintptr_t>(id);
    if (k == 1) return p->pos;
    if (k == 3) return static_cast<int>(p->data.size());
    if (k == 4) ++reads;
    if (k == 4 && p->pos >= 0 && p->pos + 4 <= static_cast<int>(p->data.size())) {
      int32_t n; std::memcpy(&n,p->data.data()+p->pos,4); p->pos += 4; return n;
    }
    error = true; return 0;
  }
  void CallVoidMethod(jobject o, jmethodID id, ...) {
    auto *p = static_cast<FixtureParcel *>(o); auto k = reinterpret_cast<uintptr_t>(id);
    va_list args; va_start(args,id); int value=va_arg(args,int); va_end(args);
    if (k == 2 && value >= 0 && value <= static_cast<int>(p->data.size())) { p->pos=value; return; }
    if (k == 5 && p->pos >= 0 && p->pos + 4 <= static_cast<int>(p->data.size())) {
      std::memcpy(p->data.data()+p->pos,&value,4); p->pos+=4; return;
    }
    error=true;
  }
  jobject CallObjectMethod(jobject o, jmethodID id, ...) {
    auto *p = static_cast<FixtureParcel *>(o);
    if (reinterpret_cast<uintptr_t>(id) != 6 || p->pos < 0 || p->pos+4 > static_cast<int>(p->data.size())) { error=true; return nullptr; }
    int32_t n; std::memcpy(&n,p->data.data()+p->pos,4); p->pos+=4;
    if (n<0 || n>100 || p->pos+2*(n+1)>static_cast<int>(p->data.size())) { error=true; return nullptr; }
    str.clear(); for (int i=0;i<n;++i) { str.push_back(char(p->data[p->pos])); p->pos+=2; }
    p->pos+=2; p->pos=(p->pos+3)&~3; return &str;
  }
  const char *GetStringUTFChars(jstring s, void *) { return static_cast<std::string *>(s)->c_str(); }
  void ReleaseStringUTFChars(jstring, const char *) {}
  void DeleteLocalRef(jobject) {}
  jclass FindClass(const char *name) {
    if (!std::strcmp(name,"android/os/Build$VERSION")) return reinterpret_cast<jclass>(11);
    if (!std::strcmp(name,"android/view/IWindowSession$Stub")) return reinterpret_cast<jclass>(12);
    if (!std::strcmp(name,"android/os/Parcel")) return reinterpret_cast<jclass>(13);
    error=true; return nullptr;
  }
  jfieldID GetStaticFieldID(jclass cls,const char *name,const char *) {
    if (cls==reinterpret_cast<jclass>(11) && !std::strcmp(name,"SDK_INT")) return reinterpret_cast<jfieldID>(20);
    if (cls==reinterpret_cast<jclass>(12) && !std::strcmp(name,"TRANSACTION_relayout")) return reinterpret_cast<jfieldID>(21);
    error=true; return nullptr;
  }
  jint sdk=37;
  jint GetStaticIntField(jclass,jfieldID id) { return id==reinterpret_cast<jfieldID>(20) ? sdk : 42; }
  jmethodID GetMethodID(jclass,const char *name,const char *) {
    const char *names[]={"dataPosition","setDataPosition","dataSize","readInt","writeInt","readString"};
    for (int i=0;i<6;++i) if (!std::strcmp(name,names[i])) return reinterpret_cast<jmethodID>(uintptr_t(i+1));
    error=true; return nullptr;
  }
};
