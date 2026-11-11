import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("io.gitlab.arturbosch.detekt")
    id("com.github.triplet.play")
}

val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingSetting(name: String): String? =
    keystoreProperties.getProperty(name) ?: providers.gradleProperty("drift.$name").orNull

android {
    namespace = "cc.hafa.drift"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "cc.hafa.drift"
        minSdk = 26
        targetSdk {
            version = release(37)
        }
        versionCode = 3
        versionName = "0.1.2"
    }

    buildFeatures {
        compose = true
    }

    // Lets setup's Logcat lines run as no-ops in JVM unit tests.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // storeFile, storePassword, keyAlias and keyPassword come from android/keystore.properties
    // (git-ignored), or from -Pdrift.<name> in CI. Without them release is debug-signed, which
    // installs locally but Play won't accept.
    val uploadStoreFile = signingSetting("storeFile")
    signingConfigs {
        if (uploadStoreFile != null) {
            create("upload") {
                storeFile = rootProject.file(uploadStoreFile)
                storePassword = signingSetting("storePassword")
                keyAlias = signingSetting("keyAlias")
                keyPassword = signingSetting("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName(if (uploadStoreFile != null) "upload" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

// Full default rule set (buildUponDefaultConfig); app-specific deviations in
// config/detekt/detekt.yml, which lives at the android root and is shared from here.
detekt {
    source.setFrom("src/main/kotlin")
    config.setFrom(rootProject.file("config/detekt/detekt.yml"))
    buildUponDefaultConfig = true
}

// publishReleaseBundle uploads to Play; credentials come from ANDROID_PUBLISHER_CREDENTIALS (.github/workflows/android-publish.yml).
play {
    track.set("internal")
    defaultToAppBundles.set(true)
}

dependencies {
    implementation("com.github.hafacc:mideakt:0.3.2")

    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // deprecated alpha; migration tracked separately
    implementation("androidx.security:security-crypto:1.1.0")
    implementation("androidx.glance:glance-appwidget:1.1.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
