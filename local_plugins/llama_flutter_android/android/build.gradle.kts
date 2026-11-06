group = "com.write4me.llama_flutter_android"
version = "1.0.0"

// Define extra properties BEFORE buildscript
extra["kotlinVersion"] = "2.1.0"

buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.9.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.write4me.llama_flutter_android"
    
    // Target Android 15 with 16KB page size support
    compileSdk = 35
    
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 28  // Android 9: matches the app; needed for Vulkan 1.1 symbols
        
        ndk {
            // arm64: full build (CPU variants + Vulkan). armeabi-v7a: plain CPU
            // build for phones running 32-bit Android (e.g. Android Go).
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
        
        externalNativeBuild {
            cmake {
                // Android 15 16KB page size compliance
                cppFlags += listOf(
                    "-std=c++17",
                    "-O3",
                    "-fvisibility=hidden"
                )
                
                // ARM64 optimization flags
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DANDROID_ARM_NEON=ON",
                    "-DGGML_CPU_AARCH64=ON",
                    "-DGGML_OPENMP=OFF"
                )
            }
        }
    }
    
    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
            // Windows MAX_PATH: the Vulkan shader generator is built as an
            // ExternalProject whose own build/object paths add ~150 chars,
            // and CMake caps object paths at 250. The default staging dir is
            // already 117 chars deep here, so point the whole native tree at
            // a short path. Override with PRIVATELM_LLAMA_CXX_DIR if needed.
            buildStagingDirectory = file(
                System.getenv("PRIVATELM_LLAMA_CXX_DIR")
                    ?: if (System.getProperty("os.name").startsWith("Windows")) {
                        "${System.getProperty("user.home").replace('\\', '/')}/pl-cxx/llama"
                    } else {
                        "${layout.buildDirectory.get().asFile}/cxx"
                    }
            )
        }
    }

    dependencies {
        implementation("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
        
        testImplementation("org.jetbrains.kotlin:kotlin-test")
        testImplementation("org.mockito:mockito-core:5.0.0")
    }

    testOptions {
        unitTests.all {
            it.useJUnitPlatform()
        }
    }
}
