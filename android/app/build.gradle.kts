import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val releaseStoreFile =
    keystoreProperties.getProperty("storeFile") ?: System.getenv("GITMIT_KEYSTORE_FILE")
val releaseStorePassword =
    keystoreProperties.getProperty("storePassword") ?: System.getenv("GITMIT_KEYSTORE_PASSWORD")
val releaseKeyAlias =
    keystoreProperties.getProperty("keyAlias") ?: System.getenv("GITMIT_KEY_ALIAS")
val releaseKeyPassword =
    keystoreProperties.getProperty("keyPassword") ?: System.getenv("GITMIT_KEY_PASSWORD")

val hasReleaseSigning =
    !releaseStoreFile.isNullOrBlank() &&
        !releaseStorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.nothix.gitmit"
    compileSdk = flutter.compileSdkVersion
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nothix.gitmit"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Keep broader device compatibility (e.g., Android 6.0 / API 23).
        minSdkVersion(23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // --- Play Store Release Preparation ---
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            // Use release signing if configured. Otherwise keep local release builds possible
            // with debug signing, but do not use that artifact for Play Console.
            signingConfig =
                signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // Enable code shrinking and obfuscation for release
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    // --- End Play Store Release Preparation ---
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
