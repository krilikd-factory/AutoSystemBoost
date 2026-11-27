#include "asb_screenshot_hook.cpp"
#include <cassert>

static int original_calls=0;
static jboolean original(JNIEnv *, jobject, jint, jobject, jobject, jint) { ++original_calls; return 1; }
static jint create_flags=0, transaction_flags=0, transaction_mask=0;
static jlong create_surface(JNIEnv *, jclass, jobject, jstring, jint, jint, jint, jint flags, jlong, jobject) { create_flags=flags; return 123; }
static void set_surface_flags(JNIEnv *, jclass, jlong, jlong, jint flags, jint mask) { transaction_flags=flags; transaction_mask=mask; }
static zygisk::Api *captured_api=nullptr; static int hook_count=0; static bool no_surface=false;
struct FixtureModule : zygisk::ModuleBase { void onLoad(zygisk::Api *api, JNIEnv *) override { captured_api=api; } };
static bool register_module(zygisk::internal::api_table *, zygisk::internal::module_abi *) { return true; }
static void hook(JNIEnv *, const char *name, JNINativeMethod *m, int n) {
  ++hook_count;
  if (!std::strcmp(name,"android/os/BinderProxy")) { assert(n==1); m[0].fnPtr=reinterpret_cast<void *>(&original); return; }
  assert(!std::strcmp(name,"android/view/SurfaceControl") && n==2);
  if (no_surface) { m[0].fnPtr=nullptr; m[1].fnPtr=nullptr; return; }
  assert(!std::strcmp(m[0].signature,"(Landroid/view/SurfaceSession;Ljava/lang/String;IIIIJLandroid/os/Parcel;)J"));
  assert(!std::strcmp(m[1].signature,"(JJII)V"));
  m[0].fnPtr=reinterpret_cast<void *>(&create_surface);
  m[1].fnPtr=reinterpret_cast<void *>(&set_surface_flags);
}

static void put(FixtureParcel &p, int pos, int32_t value) { std::memcpy(p.data.data()+pos,&value,4); }
static int32_t get(const FixtureParcel &p, int pos) { int32_t x; std::memcpy(&x,p.data.data()+pos,4); return x; }
static FixtureParcel make_parcel(const char *name, int &flags_at) {
  FixtureParcel p; p.data.resize(256); int pos=12; const int n=static_cast<int>(std::strlen(name));
  put(p,pos,n); pos+=4;
  for (int i=0;i<n;++i) { p.data[pos++]=name[i]; p.data[pos++]=0; }
  p.data[pos++]=0; p.data[pos++]=0; pos=(pos+3)&~3;
  put(p,pos+28,1); put(p,pos+32,-1); put(p,pos+36,-2); put(p,pos+40,0);
  put(p,pos+44,0); put(p,pos+48,1); put(p,pos+52,0x40002001);
  flags_at=pos+52; p.pos=7; return p;
}
int main() {
  JNIEnv env;
  assert(!original_surface_create && !original_surface_set_flags);
  assert(wrapped_surface_create(&env,nullptr,nullptr,nullptr,1,2,3,0x5c4,0,nullptr)==0);
  wrapped_surface_set_flags(&env,nullptr,1,2,0x1c1,0x1c1);
  zygisk::internal::api_table host{}; host.registerModule=register_module; host.hookJniNativeMethods=hook;
  zygisk::internal::entry_impl<FixtureModule>(&host,&env); assert(captured_api);
  env.sdk=34; assert(!asb_screenshot_install(captured_api,&env) && hook_count==0);
  env.sdk=37; assert(asb_screenshot_install(captured_api,&env) && hook_count==2);
  assert(wrapped_surface_create(&env,nullptr,nullptr,nullptr,1,2,3,0x5c4,0,nullptr)==123);
  assert(create_flags==0x504); // preserve unrelated creation flags
  wrapped_surface_set_flags(&env,nullptr,1,2,0x1c1,0x1c1);
  assert(transaction_flags==0x101 && transaction_mask==0x1c1);
  wrapped_surface_set_flags(&env,nullptr,1,2,0x101,0x1c1);
  assert(transaction_flags==0x101 && transaction_mask==0x1c1);
  get_position=reinterpret_cast<jmethodID>(1); set_position=reinterpret_cast<jmethodID>(2);
  get_size=reinterpret_cast<jmethodID>(3); read_int=reinterpret_cast<jmethodID>(4);
  write_int=reinterpret_cast<jmethodID>(5); read_string=reinterpret_cast<jmethodID>(6);
  transaction_count=1; window_transactions[0]=42;
  int at=0; auto good=make_parcel("android.view.IWindowSession",at);
  adjust_window(&env,&good,42); assert(!env.error && good.pos==7 && get(good,at)==0x40000001);
  auto ordinary=make_parcel("android.view.IWindowSession",at);
  put(ordinary,at,0x40000001); env.reads=0;
  adjust_window(&env,&ordinary,42);
  assert(!env.error && ordinary.pos==7 && get(ordinary,at)==0x40000001 && env.reads==4);
  auto wrong=make_parcel("android.view.IWindowSessioX",at);
  adjust_window(&env,&wrong,42); assert(!env.error && wrong.pos==7 && get(wrong,at)==0x40002001);
  auto other=make_parcel("android.view.IWindowSession",at);
  adjust_window(&env,&other,43); assert(other.pos==7 && get(other,at)==0x40002001);
  put(other,at-4,0); adjust_window(&env,&other,42); assert(other.pos==7 && get(other,at)==0x40002001);
  auto absent=make_parcel("android.view.IWindowSession",at);
  put(absent,at-24,0); adjust_window(&env,&absent,42); assert(absent.pos==7 && get(absent,at)==0x40002001);
  auto short_data=make_parcel("android.view.IWindowSession",at); short_data.data.resize(at+3);
  adjust_window(&env,&short_data,42); assert(!env.error && short_data.pos==7);
  auto pass=make_parcel("android.view.IWindowSession",at);
  original_transact=original;
  assert(wrapped_transact(&env,nullptr,42,&pass,nullptr,0)==1 && original_calls==1 && get(pass,at)==0x40000001);
  env.error=true; adjust_window(&env,&other,42); assert(env.error && other.pos==7);
  // Each hook family remains useful when the other is unavailable on an OEM build.
  env.error=false; env.no_window=true; original_surface_create=nullptr; original_surface_set_flags=nullptr;
  assert(asb_screenshot_install(captured_api,&env) && original_surface_create && original_surface_set_flags);
  env.no_window=false; no_surface=true; original_surface_create=nullptr; original_surface_set_flags=nullptr;
  assert(asb_screenshot_install(captured_api,&env) && !original_surface_create && !original_surface_set_flags);
}
