plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Distribution credentials are supplied only to the release build process.
// A partial configuration must never silently fall back to the debug key.
val signingEnvironment = listOf(
    "DONTFORGET_ANDROID_KEYSTORE_PATH",
    "DONTFORGET_ANDROID_STORE_PASSWORD",
    "DONTFORGET_ANDROID_KEY_ALIAS",
    "DONTFORGET_ANDROID_KEY_PASSWORD",
).associateWith { System.getenv(it).orEmpty() }
val hasDistributionSigning = signingEnvironment.values.all { it.isNotBlank() }
if ((signingEnvironment.values.any { it.isNotEmpty() } ||
        System.getenv("DONTFORGET_REQUIRE_RELEASE_SIGNING") == "1") &&
    !hasDistributionSigning) {
    throw GradleException("Complete Android distribution signing configuration is required")
}

android {
    namespace = "com.yarnway.dontforget"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yarnway.dontforget"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        multiDexEnabled = true
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasDistributionSigning) {
            create("distribution") {
                storeFile = file(signingEnvironment.getValue("DONTFORGET_ANDROID_KEYSTORE_PATH"))
                storePassword = signingEnvironment.getValue("DONTFORGET_ANDROID_STORE_PASSWORD")
                keyAlias = signingEnvironment.getValue("DONTFORGET_ANDROID_KEY_ALIAS")
                keyPassword = signingEnvironment.getValue("DONTFORGET_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasDistributionSigning) "distribution" else "debug"
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
