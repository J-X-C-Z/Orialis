plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Opt-in independent News package: `./gradlew assembleDebug -PnewsApp=true`.
// The default app keeps its existing application ID and Dart entry point.
val newsApp = providers.gradleProperty("newsApp").map(String::toBoolean).getOrElse(false)
// Separate package and data storage for physical-device joint acceptance.
val jointAcceptance = providers.gradleProperty("jointAcceptance").map(String::toBoolean).getOrElse(false)
// Disposable acceptance package with separate Android storage.
val systemAcceptance = providers.gradleProperty("systemAcceptance").map(String::toBoolean).getOrElse(false)
// Public Xiaomi identifiers, never secrets. Opt in only for the registered production package.
val xiaomiAppId = providers.gradleProperty("xiaomiAppId").getOrElse("")
val xiaomiFocusBusiness = providers.gradleProperty("xiaomiFocusBusiness").getOrElse("")

android {
    namespace = "top.jxcz.orialis"
    // file_picker's Android lifecycle dependency requires API 36 at compile time.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    if (newsApp) {
        sourceSets {
            // Merge the news-only removals over the shared launcher manifest.
            getByName("debug") {
                manifest.srcFile("src/news/AndroidManifest.xml")
            }
            getByName("release") {
                manifest.srcFile("src/news/AndroidManifest.xml")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = when {
            newsApp -> "top.jxcz.orialis.news"
            systemAcceptance -> "top.jxcz.orialis.systemacceptance"
            jointAcceptance -> "top.jxcz.orialis.jointacceptance"
            else -> "top.jxcz.orialis"
        }
        manifestPlaceholders["appLabel"] = when {
            newsApp -> "Orialis 资讯"
            systemAcceptance -> "Orialis 系统验收"
            jointAcceptance -> "Orialis 联合验收"
            else -> "Orialis"
        }
        manifestPlaceholders["appIcon"] = if (newsApp) "@mipmap/ic_launcher_news" else "@mipmap/ic_launcher"
        manifestPlaceholders["xiaomiAppId"] = if (newsApp || jointAcceptance || systemAcceptance) "" else xiaomiAppId
        manifestPlaceholders["xiaomiFocusBusiness"] = if (newsApp || jointAcceptance || systemAcceptance) "" else xiaomiFocusBusiness
        manifestPlaceholders["xiaomiDebugBuild"] = false
        manifestPlaceholders["newsCleartextTraffic"] = "false"
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
        if (newsApp && providers.gradleProperty("target-platform").orNull == "android-arm64") {
            // Do not advertise other plugin ABIs without their Flutter runtime.
            ndk.abiFilters.clear()
            ndk.abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        debug {
            manifestPlaceholders["xiaomiDebugBuild"] = true
            if (newsApp) manifestPlaceholders["newsCleartextTraffic"] = "true"
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Shrink unused plugin/Kotlin code and resources in release APKs.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
    target = if (newsApp) "lib/main_news.dart" else providers.gradleProperty("target").getOrElse("lib/main.dart")
}

dependencies {
    implementation(files("libs/xms-wearable-lib_1.4_release.aar"))
}
