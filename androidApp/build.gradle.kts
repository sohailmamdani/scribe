plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.kotlinAndroid)
    alias(libs.plugins.composeCompiler)
}

android {
    namespace = "com.sohail.scribe"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.sohail.scribe"
        minSdk = 31
        targetSdk = 36
        versionCode = 11
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets.named("main") {
        // Reuse the exact frequency-ordered dictionaries shipped by the iOS
        // keyboard instead of maintaining diverging Android copies.
        assets.srcDir(layout.buildDirectory.dir("generated/scribeAssets"))
    }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
    }
}

val generateScribeAssets by tasks.registering(Copy::class) {
    from(rootProject.file("ScribeKeyboard")) {
        include(
            "AutocorrectWords.txt",
            "AutocorrectBigrams.txt",
            "SwipeWords.txt",
            "AutocorrectData-LICENSE.txt",
        )
    }
    into(layout.buildDirectory.dir("generated/scribeAssets"))
}

tasks.named("preBuild").configure {
    dependsOn(generateScribeAssets)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core)
    implementation(libs.androidx.customview)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(kotlin("test"))
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
