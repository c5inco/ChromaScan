# ProGuard rules for ChromaScan Android Companion
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.chromascan.companion.model.**$$serializer { *; }
-keepclassmembers class com.chromascan.companion.model.** {
    *** Companion;
}
-keepclasseswithmembers class com.chromascan.companion.model.** {
    kotlinx.serialization.KSerializer serializer(...);
}
