import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase, but only once somebody has actually created the project.
//
// The google-services plugin fails the build outright when the JSON is
// missing, and the JSON is a per-project credential that cannot be committed —
// so applying it unconditionally would mean nobody can build the app until the
// Firebase console work is done. Push is an addition; it must not become a
// prerequisite for compiling an attendance app.
//
// Drop google-services.json into this directory and the next build picks it up
// with no further edit. See Push-Notifications_Setup.md.
val firebaseConfig = file("google-services.json")
if (firebaseConfig.exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.lifecycle(
        "google-services.json not found — building without push. " +
            "See Push-Notifications_Setup.md."
    )
}

// Release signing is read from android/key.properties, which is gitignored and
// never committed — a keystore in version control can sign a malicious update
// that Play will accept as genuine. Absent, the build falls back to the debug
// key so `flutter run --release` still works locally; that build simply cannot
// be uploaded, which is the correct failure.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.hrms.attendance"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // Permanent: this is the Play Store identity and cannot be changed
        // after the first upload.
        applicationId = "com.hrms.attendance"

        // Pinned to 23 because firebase_core requires it, and left as a floor
        // rather than a fixed value so a future Flutter whose own minimum is
        // higher still wins. Below 23 the Firebase SDK fails to merge its
        // manifest, with an error that names an AAR rather than this line.
        minSdk = maxOf(flutter.minSdkVersion, 23)

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // The debug key is a well-known shared key — Play rejects anything
            // signed with it. Falling back keeps local release builds working
            // while making a real upload impossible until the keystore exists.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
