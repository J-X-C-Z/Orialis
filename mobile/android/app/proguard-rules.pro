# Flutter embedding and plugins keep JNI/reflection entry points.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Used by flutter_secure_storage / platform channels via reflection.
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.lifecycle.** { *; }

# file_picker and image_picker touch content resolvers and providers.
-keep class androidx.core.content.FileProvider { *; }
-keep class ** extends androidx.core.content.FileProvider { *; }
