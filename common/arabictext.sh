#!/system/bin/sh

# Arabic installer strings.
#
# Partial by design: install.sh sources englishtext.sh first and then this file, so
# anything not translated here stays readable English rather than blank.

# Arabic is right-to-left. These strings are only ever printed by ui_print into the
# root manager's console, which lays out text itself - there is no layout of ours to
# mirror. The WebUI is a different matter and sets dir="rtl" separately.

ASB_HINT="[VOL+] تفعيل | [VOL-] تخطي"
ASB_TIMEOUT="! انتهى الوقت (10 ثوانٍ). تم إلغاء التثبيت."
ASB_HELP="VOL+ = تفعيل  |  VOL- = تخطي  |  مهلة 10 ثوانٍ = إلغاء"
ASB_SEC_DEVICE="الجهاز"
ASB_SEC_CONFIG="الإعدادات"
ASB_SEC_GOVERNOR="المنظّم"
ASB_SEC_AUDIO="الصوت"
ASB_SEC_CAMERA="الكاميرا"
ASB_SEC_MEDIA="الوسائط"
ASB_SEC_PERF="الأداء"
ASB_SEC_LOCATION="الموقع"
ASB_SEC_WIFI="واي فاي"
ASB_SEC_SYSTEM="النظام"
ASB_SEC_CATEGORIES="المكونات المُعَدّة"
ASB_L_MIRROR_AUDIO_TOTAL="تمت مطابقة %s من ملفات إعدادات الصوت من %s من مسارات الجهاز كي يعدّلها ASB بأمان"
ASB_SEC_INSTALLING="جارٍ التثبيت لـ"
ASB_SEC_BUILDING="إنشاء طبقة من ملفات هذا الهاتف الأصلية"
ASB_SEC_NOTICE="ما الذي ستلاحظه"
ASB_SEC_DSP="محرك DSP"
ASB_SEC_DISPLAY="الشاشة"
ASB_SEC_HAPTICS="الاهتزاز"
ASB_SEC_BATTERY="البطارية"
ASB_SEC_MEMORY="الذاكرة"
ASB_L_NOTICE_FOOT1="كل ما سبق قابل للتعديل في واجهة الويب، وإعادة التشغيل"
ASB_L_NOTICE_FOOT2="تطبّق الأجزاء التي تحتاج إليها."
