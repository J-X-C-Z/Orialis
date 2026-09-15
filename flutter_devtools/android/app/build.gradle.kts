<<<<<<< HEAD
import org.gradle.api.tasks.Copy

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

<<<<<<< HEAD
val sharedWristbandSources = layout.buildDirectory.dir("generated/shared-wristband-sources")
tasks.register<Copy>("syncSharedWristbandSources") {
    from(file("../../../android/app/src/main/java/app/fangcun"))
    include("WristbandAdapter.java", "XiaomiWristbandAdapter.java")
    into(sharedWristbandSources)
}

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
android {
    namespace = "app.fangcun.fangcun_devtools"
    compileSdk = flutter.compileSdkVersion
    // This scaffold currently has no native C/C++ plugin. Leaving NDK
    // selection to AGP avoids forcing a local NDK download for the console.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
<<<<<<< HEAD
        // Match the Vela RPK package for Xiaomi system.interconnect.
        applicationId = "app.fangcun"
=======
        applicationId = "app.fangcun.fangcun_devtools"
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

<<<<<<< HEAD
    // Reuse the production adapter source while Flutter replaces the WebView
    // shell. Keeping one adapter implementation prevents protocol drift.
    sourceSets {
        getByName("main").java {
            srcDir(sharedWristbandSources.get().asFile)
        }
    }

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // The local SDK may not have llvm-strip yet; keeping symbols is
            // appropriate for this developer-only debug scaffold.
            keepDebugSymbols += "**/*.so"
        }
    }
}

<<<<<<< HEAD
tasks.named("preBuild").configure { dependsOn("syncSharedWristbandSources") }

dependencies {
    implementation(files("../../../android/app/libs/xms-wearable-lib_1.4_release.aar"))
    implementation("androidx.work:work-runtime:2.10.1")
}

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
